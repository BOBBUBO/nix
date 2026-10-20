#!/data/data/com.termux/files/usr/bin/bash
#
# Nix on Termux — one-shot native build & install.
#
# Compiles the patched Nix tree in this repository on-device (bionic/Android),
# installs it into $PREFIX, sets up the store/state dirs and nix.conf, and runs
# a smoke test (including nix-env). Before doing anything it checks the device
# for problems and prints warnings (or aborts) when something is missing or
# unsupported.
#
# Usage:
#   bash packaging/termux/build.sh            # full: checks → deps → build → install → smoke test
#   bash packaging/termux/build.sh --check    # only run the device checks, then exit
#
# Options:
#   --check          pre-flight device checks only (no modifications)
#   --no-deps        skip installing packages (assumes they're present; still verifies)
#   --no-build       skip configure/build/install (deps + runtime setup only)
#   --keep           keep the temporary build directory
#   --build-dir DIR  use DIR for the build (instead of a temp dir)
#   --destdir DIR    stage the install into DIR (for make-deb.sh) instead of $PREFIX
#   --jobs N         build with N parallel jobs (default: nproc)
#   --debug          configure a debug build (default: release)
#
# Exit codes: 0 ok, 1 error, 2 device unsupported, 3 build failure.

set -euo pipefail

# --- configuration -----------------------------------------------------------

PREFIX="${PREFIX:-}"
BUILD_DIR=""
DESTDIR=""
JOBS="$(nproc 2>/dev/null || echo 4)"
DO_DEPS=1
DO_BUILD=1
KEEP=0
MODE="all"
BUILDTYPE="release"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
NIX_BIN="$PREFIX/bin/nix"

NC='\033[0m'; BOLD='\033[1m'; RED='\033[31m'; YEL='\033[33m'; GRN='\033[32m'

msg()  { printf "${BOLD}[NIX-TERMUX]${NC} %s\n" "$*"; }
info() { printf "  ${GRN}[INFO]${NC} %s\n" "$*"; }
warn() { printf "  ${YEL}[WARN]${NC} %s\n" "$*"; }
die()  { printf "  ${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }

usage() {
    sed -n '2,25p' "$0"
    exit 0
}

# --- pre-flight checks ---------------------------------------------------------

check_termux() {
    msg "Checking environment..."
    if [ -z "$PREFIX" ]; then
        die "PREFIX is empty — this script must run inside Termux (where PREFIX is set)."
    fi
    if [ ! -d "$PREFIX" ]; then
        die "PREFIX ($PREFIX) is not a directory — this does not look like a Termux environment."
    fi
    if [ "$(id -u)" = "0" ]; then
        warn "Running as root. Termux normally runs unprivileged; Nix will use root profiles."
    fi
    if [ ! -x "$(command -v pkg)" ]; then
        die "'pkg' not found — Termux package manager is missing. Is this really Termux?"
    fi
    if [ ! -r /system/build.prop ] && ! command -v getprop >/dev/null 2>&1; then
        warn "Cannot read Android properties — expected on Termux; continuing anyway."
    fi
    if ! command -v getprop >/dev/null 2>&1 || [ -z "$(getprop ro.build.version.sdk 2>/dev/null)" ]; then
        warn "Could not determine the Android API level (not running under Android?)."
    fi
    info "PREFIX=$PREFIX  user=$(id -un)  arch=$(uname -m)"
}

check_arch() {
    local arch
    arch="$(uname -m)"
    case "$arch" in
        aarch64|arm64|arm64-v8a)
            info "Architecture $arch: supported (this is what Nix was verified on)." ;;
        x86_64|amd64)
            warn "Architecture $arch: untested. Nix is architecture-neutral and the
                  patches contain no arch-specific code, so it should work — but no guarantee." ;;
        armv7l|armv8l|armv6l|i686|x86|riscv64)
            warn "Architecture $arch: 32-bit or uncommon ABI — untested.
                  Nix may work, but 32-bit Android userspaces are a shrinking target." ;;
        *)
            warn "Unknown architecture '$arch' — proceeding at your own risk." ;;
    esac
}

check_android_version() {
    local sdk=""
    command -v getprop >/dev/null 2>&1 && sdk="$(getprop ro.build.version.sdk 2>/dev/null || true)"
    if [ -z "$sdk" ]; then
        warn "Could not read Android API level."
        return
    fi
    case "$sdk" in
        *[!0-9]*) warn "Unrecognised Android API level '$sdk'."; return ;;
    esac
    if [ "$sdk" -lt 24 ]; then
        die "Android API $sdk is too old — Termux (and therefore Nix) requires Android 7 (API 24) or newer."
    fi
    info "Android API level $sdk (>= 24 required): OK."
    if [ "$sdk" -lt 28 ]; then
        warn "Android $sdk is old; Termux may already be EOL for it. Untested."
    fi
}

check_kernel() {
    local major="" rest="" minor=""
    # uname(2) works everywhere; /proc/sys/kernel/osrelease may be blocked by SELinux.
    if [ -r /proc/sys/kernel/osrelease ]; then
        read -r major rest < /proc/sys/kernel/osrelease || true
        minor="${rest%%.*}"
    else
        rest="$(uname -r 2>/dev/null || true)"
        major="${rest%%.*}"
        minor="${rest#*.}"
        minor="${minor%%.*}"
    fi
    [ -n "$major" ] || { warn "Cannot read kernel version."; return; }
    case "$major" in *[!0-9]*) warn "Cannot parse kernel version '$major.$minor'."; return ;; esac
    case "$minor" in ''|*[!0-9]*) warn "Cannot parse kernel version '$major.$minor'."; return ;; esac
    info "Kernel $major.$minor: OK."
    if [ "$major" -lt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -lt 9 ]; }; then
        warn "Kernel < 5.9 lacks close_range(2). Nix falls back to /proc/self/fd
              scanning, so everything still works — just slightly slower."
    fi
}

check_disk() {
    local avail_kb avail_gb
    avail_kb="$(df -Pk "$PREFIX" 2>/dev/null | awk 'END {print $4}')"
    if [ -z "$avail_kb" ]; then
        warn "Cannot determine free space on $PREFIX."
        return
    fi
    avail_gb=$((avail_kb / 1024 / 1024))
    info "Free space on $PREFIX: ${avail_gb} GiB."
    if [ "$avail_gb" -lt 2 ]; then
        die "Only ${avail_gb} GiB free — a Nix build needs several GiB (store + objects)."
    fi
    if [ "$avail_gb" -lt 8 ]; then
        warn "Only ${avail_gb} GiB free — enough, but a full build plus the Nix store is tight."
    fi
}

check_store_fs() {
    # The Nix store must be on a real filesystem (ext4/f2fs), not FUSE (SD cards).
    local d="$PREFIX" fs=""
    while :; do
        fs="$(awk -v d="$d" '$2==d {print $3; exit}' /proc/mounts 2>/dev/null)"
        [ -n "$fs" ] && break
        [ "$d" = "/" ] && break
        d="${d%/*}"
        [ -n "$d" ] || d="/"
    done
    [ -z "$fs" ] && { warn "Cannot determine filesystem type of $PREFIX."; return; }
    info "Filesystem for $PREFIX: $fs."
    case "$fs" in
        fuse*|sdcardfs|vfat|exfat|ntfs|mtp*|tmpfs)
            die "The Nix store would live on '$fs' — FUSE/external storage cannot
                 provide the hardlinks/chown the store needs. Move Termux to internal
                 storage (/data) first. See README.md → Device support."
            ;;
    esac
}

check_tmp() {
    if [ ! -d "$PREFIX/tmp" ]; then
        warn "$PREFIX/tmp does not exist — creating it."
        mkdir -p "$PREFIX/tmp" 2>/dev/null || true
    fi
    if ! touch "$PREFIX/tmp/.nix-touch-test" 2>/dev/null; then
        die "Cannot write to $PREFIX/tmp — Termux temp dir is not writable."
    fi
    rm -f "$PREFIX/tmp/.nix-touch-test"
    info "Temp dir $PREFIX/tmp: writable."
}

check_tools() {
    local missing=0 t
    for t in git curl cmake clang ninja pip pkg-config make; do
        command -v "$t" >/dev/null 2>&1 || { warn "Tool '$t' not found (it will be installed with the packages)."; missing=1; }
    done
    [ "$missing" = 1 ] && info "Run without --no-deps to install missing tools."
}

preflight() {
    check_termux
    check_arch
    check_android_version
    check_kernel
    check_disk
    check_store_fs
    check_tmp
    check_tools
}

# --- dependencies --------------------------------------------------------------

install_packages() {
    local pkg_list
    pkg_list="ninja nlohmann-json boost boost-headers libseccomp libsodium libgc \
              libgit2 lowdown libedit readline libarchive libcurl libsqlite openssl \
              brotli zstd xz-utils liblz4 bison flex clang cmake git python pip \
              pkg-config busybox toml11"
    msg "Installing packages (pkg install -y)..."
    pkg install -y $pkg_list
    python -m pip install --break-system-packages --upgrade meson
    msg "Packages installed."
}

verify_deps() {
    msg "Verifying required libraries are present..."
    local missing=""
    for pc in libcurl libsodium libgit2 lowdown nlohmann_json libseccomp bdw-gc libedit readline zlib libzstd liblzma liblz4 libarchive; do
        pkg-config --exists "$pc" 2>/dev/null || missing="$missing $pc"
    done
    if [ -n "$missing" ]; then
        die "Missing pkg-config packages:$missing — run without --no-deps, or 'pkg install' them."
    fi
    if [ ! -f "$PREFIX/include/boost/version.hpp" ]; then
        die "Boost headers not found — 'pkg install boost-headers' is required (meson cannot find Boost otherwise)."
    fi
    if [ ! -f "$PREFIX/lib/cmake/toml11/toml11Config.cmake" ]; then
        die "toml11 CMake package not found — 'pkg install toml11' is required."
    fi
    if ! command -v meson >/dev/null 2>&1 || ! meson --version >/dev/null 2>&1; then
        die "meson not found — 'pip install meson' is required."
    fi
    info "All libraries verified."
}

ensure_blake3() {
    if pkg-config --exists libblake3 2>/dev/null; then
        info "libblake3 already present."
        return
    fi
    msg "Building libblake3 from source (not in Termux repos)..."
    local bdir="$BUILD_DIR/blake3"
    rm -rf "$bdir"
    git clone --depth 1 https://github.com/BLAKE3-team/BLAKE3 "$bdir" 2>&1 | tail -2 || die "Failed to clone BLAKE3."
    cmake -S "$bdir/c" -B "$bdir/c/build" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" >/dev/null || die "BLAKE3 cmake configure failed."
    cmake --build "$bdir/c/build" -j"$JOBS" >/dev/null || die "BLAKE3 build failed."
    cmake --install "$bdir/c/build" >/dev/null || die "BLAKE3 install failed."
    info "libblake3 installed."
}

ensure_gc_headers() {
    local inc="$PREFIX/include/gc" missing=0
    mkdir -p "$inc"
    [ -f "$inc/gc_cpp.h" ] || missing=1
    [ -f "$inc/gc_allocator.h" ] || missing=1
    if [ "$missing" = 0 ]; then
        info "libgc C++ headers present."
        return
    fi
    msg "Fetching missing libgc C++ headers from bdwgc v8.2.12..."
    curl -fsSL --max-time 60 \
        https://raw.githubusercontent.com/ivmai/bdwgc/v8.2.12/include/gc_cpp.h \
        -o "$inc/gc_cpp.h" || die "Failed to fetch gc_cpp.h."
    curl -fsSL --max-time 60 \
        https://raw.githubusercontent.com/ivmai/bdwgc/v8.2.12/include/gc_allocator.h \
        -o "$inc/gc_allocator.h" || die "Failed to fetch gc_allocator.h."
    info "libgc C++ headers installed."
}

# --- build -----------------------------------------------------------------------

build_nix() {
    msg "Configuring meson build (this takes a few minutes to compile)..."
    export BOOST_INCLUDEDIR="$PREFIX/include"
    export BOOST_LIBRARYDIR="$PREFIX/lib"
    # Meson's cmake-method lookups (toml11) need to search Termux's prefix,
    # which is not one of CMake's default system prefixes.
    export CMAKE_PREFIX_PATH="${CMAKE_PREFIX_PATH:-$PREFIX}"
    meson setup "$BUILD_DIR/build" "$REPO_DIR" \
        --prefix="$PREFIX" \
        --buildtype="$BUILDTYPE" \
        -Dunit-tests=false \
        -Dfunctional-tests=false \
        -Ddoc-gen=false \
        -Djson-schema-checks=false \
        -Dnix-store:seccomp-sandboxing=auto \
        -Dlibcmd:readline-flavor=readline \
        -Dlibstore:store-dir="$PREFIX/nix/store" \
        -Dlibstore:log-dir="$PREFIX/var/log/nix" \
        --localstatedir="$PREFIX/var" \
        --sysconfdir="$PREFIX/etc" \
        || die "meson setup failed."
    ninja -C "$BUILD_DIR/build" -j"$JOBS" || die "Build failed (see errors above)."
    if [ -n "$DESTDIR" ]; then
        DESTDIR="$DESTDIR" ninja -C "$BUILD_DIR/build" install || die "Install into DESTDIR failed."
        msg "Nix staged into $DESTDIR (run packaging/termux/make-deb.sh to package it)."
    else
        ninja -C "$BUILD_DIR/build" install || die "Install failed."
        msg "Nix built and installed."
    fi
}

setup_runtime() {
    msg "Setting up store dirs and nix.conf..."
    mkdir -p "$PREFIX/var/nix" "$PREFIX/nix/store" "$PREFIX/etc/nix" \
             "$PREFIX/var/log/nix" "$PREFIX/var/nix/builds" "$PREFIX/var/nix/profiles"
    if [ ! -f "$PREFIX/etc/nix/nix.conf" ]; then
        cat > "$PREFIX/etc/nix/nix.conf" <<EOF
# Native Termux build of Nix.
# Sandboxing cannot work on Android (no user namespaces / no chroot without
# root), so builds run in no-sandbox fallback mode.
sandbox = false
# cache.nixos.org serves paths under /nix/store, which cannot match this
# store's $PREFIX/nix/store prefix. Disable substitution to avoid pointless
# cache queries; re-enable it if you relocate the store to /nix/store.
substitute = false
# Keep build scratch space and logs under \$PREFIX: /tmp does not exist on
# Android, and external storage cannot hold the store.
build-dir = $PREFIX/var/nix/builds
log-dir = $PREFIX/var/log/nix
# The binary cache serves paths under /nix/store, so substitution from
# cache.nixos.org is disabled by default. Enable if you relocate the store:
#   store = /nix/store
# Legacy commands (nix-env, nix-channel) and flakes are both useful on Termux.
experimental-features = nix-command flakes
EOF
        info "Wrote $PREFIX/etc/nix/nix.conf"
    else
        info "$PREFIX/etc/nix/nix.conf already exists — leaving it untouched."
    fi
    "$PREFIX/bin/nix-store" --init >/dev/null 2>&1 \
        || warn "nix-store --init failed; the smoke test below will show the error."
}

smoke_test() {
    msg "Smoke test..."
    export NIX_CONFIG="experimental-features = nix-command flakes"
    # Use a throwaway HOME so the test does not touch the invoking user's real
    # profile (and is independent of any existing nix profile/manifest).
    export HOME="$BUILD_DIR/home"
    mkdir -p "$HOME"
    local v out expr

    v="$("$NIX_BIN" --version 2>&1)" || die "nix --version failed: $v"
    info "$v"
    out="$("$NIX_BIN" eval --expr '1 + 2' 2>&1)" || die "nix eval failed: $out"
    info "nix eval '1 + 2' -> $out"

    # nix-env works on a user profile. Install a self-contained derivation
    # (stock nixpkgs cannot bootstrap on Android — see README limitations).
    v="$("$NIX_BIN-env" --version 2>&1)" || die "nix-env --version failed: $v"
    info "nix-env: $v"

    expr="$BUILD_DIR/nix-env-smoke.nix"
    cat > "$expr" <<EOF
{
  termux-hello = builtins.derivation {
    name = "termux-hello";
    system = builtins.currentSystem;
    builder = "$PREFIX/bin/bash";
    args = [ "-c" "$PREFIX/bin/mkdir -p \$out/bin && echo hello-from-termux > \$out/bin/hello" ];
  };
}
EOF
    "$NIX_BIN-env" --option substitute false --option sandbox false \
        -f "$expr" -i termux-hello || die "nix-env install failed."
    out="$("$NIX_BIN-env" -q 2>&1)" || die "nix-env query failed: $out"
    printf '%s\n' "$out" | grep -q '^termux-hello$' \
        || die "nix-env install did not register termux-hello (got: $out)"
    [ -e "$HOME/.nix-profile/bin/hello" ] \
        || die "nix-env profile does not contain bin/hello (profile creation failed)."
    info "nix-env install/query -> termux-hello (profile link OK)"
    "$NIX_BIN-env" -e termux-hello || die "nix-env uninstall failed."
    info "nix-env uninstall -> OK"
}

finish() {
    if [ -n "$DESTDIR" ]; then
        msg "Done. Staged tree: $DESTDIR"
        cat <<EOF

Package it into a Termux .deb with:
  bash packaging/termux/make-deb.sh "$DESTDIR"
EOF
        return
    fi
    msg "Done."
    cat <<EOF

Nix is installed and usable. Try:
  nix eval --expr '1 + 2'
  nix eval --expr 'builtins.currentSystem'
  nix-env -q
  echo '1 + 2' | nix repl

Notes:
  - Store:    $PREFIX/nix/store
  - State:    $PREFIX/var/nix
  - Config:   $PREFIX/etc/nix/nix.conf
  - Sandboxing is off (Android limitation) — see README.md "Known limitations".
  - Stock nixpkgs packages cannot bootstrap on Android; self-contained
    derivations and evaluation/substitution-less builds do work.
EOF
}

# --- main ----------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --check) MODE="check" ;;
        --no-deps) DO_DEPS=0 ;;
        --no-build) DO_BUILD=0 ;;
        --keep) KEEP=1 ;;
        --build-dir) shift; BUILD_DIR="$1" ;;
        --destdir) shift; DESTDIR="$1" ;;
        --jobs) shift; JOBS="$1" ;;
        --debug) BUILDTYPE="debug" ;;
        -h|--help) usage ;;
        *) die "Unknown option '$1' (try --help)." ;;
    esac
    shift
done

preflight

if [ "$MODE" = "check" ]; then
    msg "Pre-flight checks passed. This device should be able to build and run Nix."
    exit 0
fi

if [ -z "$BUILD_DIR" ]; then
    BUILD_DIR="$(mktemp -d "$PREFIX/tmp/nix-build-XXXXXX")"
    trap '[ "$KEEP" = 1 ] || rm -rf "$BUILD_DIR"' EXIT
fi
mkdir -p "$BUILD_DIR"

if [ "$DO_DEPS" = 1 ]; then
    install_packages
fi
verify_deps
ensure_blake3
ensure_gc_headers

if [ "$DO_BUILD" = 1 ]; then
    build_nix
    if [ -z "$DESTDIR" ]; then
        setup_runtime
        smoke_test
    fi
fi

finish
