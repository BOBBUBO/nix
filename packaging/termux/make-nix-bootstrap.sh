#!/bin/bash
# make-nix-bootstrap.sh [arch] [path-to-nix.deb] [options]
#
# Builds nix-bootstrap-<arch>.zip: a Termux bootstrap that has Nix available
# out of the box and no apt/dpkg at all.
#
# Base
#   The apk-tools bootstrap is used as the base: that is the stock Termux
#   bootstrap with the apt/dpkg stack stripped, `apk` as the package manager,
#   an apk-backed `pkg` shim and an apk-based bootstrap second stage. It is
#   reused from the local apk-tools checkout when one is available
#   (../apk-tools/make-apk-bootstrap.sh), otherwise the published
#   apk-bootstrap-<arch>.zip is downloaded.
#
# Nix
#   The nix .deb (from CI, or a local path) is injected together with its
#   runtime dependencies, the store/state layout, nix.conf and a first-login
#   hook. The bootstrap second stage is replaced with a combined apk + nix
#   variant, so that a single stage initialises both databases.
#
# The result is a bootstrap where apk manages packages and Nix manages Nix
# store paths; apt/dpkg are gone. Install it on a device with
# packaging/termux/install-nix-bootstrap.sh (usr/usern swap, no app rebuild).
#
# Requires: bash, curl, unzip, zip, tar, ar, xz/zstd/bzip2 (as needed by the
#           debs), and gh only when the nix deb is not given locally.
set -eu

TERMUX_PREFIX="/data/data/com.termux/files/usr"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

TERMUX_REPO="https://packages-cf.termux.dev/apt/termux-main"
# Where the apk-tools checkout lives (a separate repository next to this one).
APK_TOOLS_DIR="${APK_TOOLS_DIR:-$(dirname "$REPO_DIR")/apk-tools}"
# Published apk bootstrap zips live in the apk-termux-repo.
APK_BOOTSTRAP_URL_BASE="${APK_BOOTSTRAP_URL_BASE:-https://raw.githubusercontent.com/BOBBUBO/apk-termux-repo/main/bootstrap}"

ARCH=""
NIX_DEB=""
APK_BOOTSTRAP=""
APKTOOLS_DEB=""
NIX_DEB_SET=0
REFRESH_BASE=0

MOTD="$SCRIPT_DIR/motd"

die() { echo "error: $*" >&2; exit 1; }
# Logs go to stderr so that functions returning a path on stdout stay clean.
log() { echo "[*] $*" >&2; }

usage() {
	cat <<EOF
usage: make-nix-bootstrap.sh [arch] [path-to-nix.deb] [options]

  arch              target architecture (default: aarch64)
  path-to-nix.deb   nix .deb to inject (default: latest CI artifact via gh)

options:
  --apk-bootstrap FILE|URL   use this apk bootstrap as the base
                              (default: build it with ../apk-tools, else download)
  --apk-tools-deb FILE       apk-tools .deb to inject when the base has no apk
  --refresh-base             rebuild the cached apk bootstrap
  --arch ARCH                same as the positional arch
  --nix-deb FILE             same as the positional nix deb
  -h, --help                 show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--apk-bootstrap) shift; APK_BOOTSTRAP="$1" ;;
		--apk-tools-deb) shift; APKTOOLS_DEB="$1" ;;
		--refresh-base) REFRESH_BASE=1 ;;
		--arch) shift; ARCH="$1" ;;
		--nix-deb) shift; NIX_DEB="$1"; NIX_DEB_SET=1 ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option '$1' (try --help)" ;;
		*)
			if [ -z "$ARCH" ]; then
				ARCH="$1"
			elif [ "$NIX_DEB_SET" = 0 ] && [ -z "$NIX_DEB" ]; then
				NIX_DEB="$1"
			else
				die "unexpected argument '$1'"
			fi ;;
	esac
	shift
done
ARCH="${ARCH:-aarch64}"
WORKDIR="$SCRIPT_DIR/.nix-bootstrap/$ARCH"
CACHEDIR="$SCRIPT_DIR/.nix-bootstrap/cache"
OUT="$SCRIPT_DIR/nix-bootstrap-$ARCH.zip"

for cmd in curl unzip zip tar ar; do
	command -v "$cmd" >/dev/null || die "missing tool: $cmd"
done

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/debs" "$WORKDIR/tree" "$CACHEDIR"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
download() {
	# $1 = url, $2 = destination
	if [ -f "$2" ]; then
		return 0
	fi
	log "downloading: $1"
	curl -fL --progress-bar -o "$2.tmp" "$1" \
		&& mv "$2.tmp" "$2" \
		|| { rm -f "$2.tmp"; return 1; }
}

# The bootstrap tree root is $PREFIX itself (no data/data/... prefix).
BOOT="$WORKDIR/tree"

extract_deb() {
	# $1 = deb path; extracts data.tar.* under $TERMUX_PREFIX into the tree
	local tmp="$WORKDIR/deb-x"
	local deb
	deb="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
	rm -rf "$tmp"; mkdir -p "$tmp"
	(cd "$tmp" && ar x "$deb" && \
		for d in data.tar.xz data.tar.gz data.tar.zst data.tar.bz2 data.tar; do
			[ -f "$d" ] && tar xf "$d" && break
		done && \
		tar -C "${TERMUX_PREFIX#/}" -cf - . | tar -C "$BOOT" -xf -)
	rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# 1. base bootstrap: the apk-tools bootstrap (no apt/dpkg, apk as manager)
# ---------------------------------------------------------------------------
resolve_base_bootstrap() {
	# 1. explicitly given
	if [ -n "$APK_BOOTSTRAP" ]; then
		case "$APK_BOOTSTRAP" in
			http://*|https://*)
				local dest="$CACHEDIR/apk-bootstrap-$ARCH.zip"
				download "$APK_BOOTSTRAP" "$dest" || die "cannot download $APK_BOOTSTRAP"
				echo "$dest" ;;
			*)
				[ -f "$APK_BOOTSTRAP" ] || die "no such bootstrap: $APK_BOOTSTRAP"
				echo "$APK_BOOTSTRAP" ;;
		esac
		return 0
	fi

	# 2. build it with the local apk-tools checkout
	local script="$APK_TOOLS_DIR/make-apk-bootstrap.sh"
	local cached="$CACHEDIR/apk-bootstrap-$ARCH.zip"
	if [ -x "$script" ] && { [ ! -f "$cached" ] || [ "$REFRESH_BASE" = 1 ]; }; then
		log "building apk bootstrap with $script"
		if [ -n "$APKTOOLS_DEB" ]; then
			(cd "$APK_TOOLS_DIR" && ./make-apk-bootstrap.sh "$ARCH" "$APKTOOLS_DEB") >&2 \
				|| die "apk-tools bootstrap build failed"
		else
			(cd "$APK_TOOLS_DIR" && ./make-apk-bootstrap.sh "$ARCH") >&2 \
				|| die "apk-tools bootstrap build failed (pass --apk-tools-deb or install gh)"
		fi
		local built="$APK_TOOLS_DIR/apk-bootstrap-$ARCH.zip"
		[ -f "$built" ] || die "apk-tools did not produce $built"
		# Keep our own copy so the base stays stable even if the apk-tools
		# checkout is rebuilt later.
		cp -f "$built" "$cached"
		echo "$cached"
		return 0
	fi
	if [ -f "$cached" ]; then
		log "using cached apk bootstrap: $cached"
		echo "$cached"
		return 0
	fi

	# 3. published apk bootstrap
	local dest="$CACHEDIR/apk-bootstrap-$ARCH.zip"
	log "no local apk-tools checkout, using the published apk bootstrap"
	download "$APK_BOOTSTRAP_URL_BASE/apk-bootstrap-$ARCH.zip" "$dest" \
		|| die "cannot download the apk bootstrap"
	echo "$dest"
}

BASE_ZIP="$(resolve_base_bootstrap)"
log "base bootstrap: $BASE_ZIP"
log "extracting base bootstrap..."
unzip -q "$BASE_ZIP" -d "$WORKDIR/tree"

# Bootstrap zips store symlinks in SYMLINKS.txt instead of the tree; recreate
# them so the injection steps see a real tree (and so we can regenerate the
# list afterwards).
log "materializing symlinks..."
while IFS='←' read -r target link; do
	[ -n "$target" ] || continue
	link="${link#./}"
	mkdir -p "$WORKDIR/tree/$(dirname "$link")"
	ln -sf "$target" "$WORKDIR/tree/$link"
done < "$WORKDIR/tree/SYMLINKS.txt"

# ---------------------------------------------------------------------------
# 2. make sure apt/dpkg are gone for good
# ---------------------------------------------------------------------------
log "stripping apt/dpkg..."
APT_PKGS="apt libapt-pkg dpkg termux-keyring"
for pkg in $APT_PKGS; do
	lf="$BOOT/var/lib/dpkg/info/$pkg.list"
	if [ -f "$lf" ]; then
		while read -r f; do
			f="${f#/}"
			f="${f#data/data/com.termux/files/usr/}"
			f="${f#./}"
			case "$f" in ""|".") continue;; esac
			if [ -f "$BOOT/$f" ] || [ -L "$BOOT/$f" ]; then
				rm -f "$BOOT/$f"
			fi
		done < "$lf"
	fi
	rm -f "$BOOT"/var/lib/dpkg/info/"$pkg".*
done
rm -rf "$BOOT/etc/apt" \
	"$BOOT/var/lib/dpkg" \
	"$BOOT/var/lib/apt" \
	"$BOOT/var/cache/apt" \
	"$BOOT/var/log/apt" \
	"$BOOT/share/termux-keyring"
rm -f "$BOOT/bin/apt" "$BOOT/bin/apt-get" "$BOOT/bin/apt-cache" \
	"$BOOT/bin/apt-config" "$BOOT/bin/apt-key" "$BOOT/bin/dpkg" \
	"$BOOT/bin/dpkg-deb" "$BOOT/bin/dpkg-query" "$BOOT/bin/dpkg-trigger"
# tmp/ must exist (lock files land in $PREFIX/tmp)
install -dm700 "$BOOT/tmp"

# ---------------------------------------------------------------------------
# 3. apk must be present: it replaces apt as the package manager
# ---------------------------------------------------------------------------
if [ ! -x "$BOOT/bin/apk" ]; then
	[ -n "$APKTOOLS_DEB" ] || die "the base bootstrap has no apk; pass --apk-tools-deb FILE"
	log "injecting apk-tools: $APKTOOLS_DEB"
	extract_deb "$APKTOOLS_DEB"
fi

# The pkg wrapper must talk to apk, not to the removed apt.
if [ ! -x "$BOOT/bin/pkg" ] || grep -q 'apt-get' "$BOOT/bin/pkg" 2>/dev/null; then
	log "installing apk-backed pkg shim..."
	cat > "$BOOT/bin/pkg" <<- 'EOF'
	#!/data/data/com.termux/files/usr/bin/sh
	# compatibility shim mapping 'pkg' verbs to apk
	# This replaces Termux's apt-based pkg wrapper for apk-based systems.

	set -e

	# ensure apk db exists
	[ -f /data/data/com.termux/files/usr/lib/apk/db/installed ] || apk add --initdb >/dev/null 2>&1 || true

	case "$1" in
		install)           shift; exec apk add "$@" ;;
		reinstall)         shift; exec apk add --force-reinstall "$@" ;;
		remove|uninstall)  shift; exec apk del "$@" ;;
		autoremove)        shift; exec apk del "$@" ;;
		search)            shift; exec apk search "$@" ;;
		show|info)         shift; exec apk info "$@" ;;
		files)             shift; exec apk info -L "$@" ;;
		list-installed)    exec apk list -I ;;
		list-all)          exec apk list -a ;;
		list-upgradable)   exec apk list -u ;;
		update)            exec apk update ;;
		upgrade)           shift || :; exec apk upgrade "$@" ;;
		dist-upgrade)      shift || :; exec apk upgrade "$@" ;;
		clean|autoclean)   exec apk cache clean ;;
		purge)             shift; exec apk del --purge "$@" ;;
		policy)            shift; exec apk policy "$@" ;;
		depends)           shift; exec apk info -d "$@" ;;
		rdepends)          shift; exec apk info -r "$@" ;;
		*) echo "pkg -> apk shim; unknown verb '$1', try: install, remove, search, update, upgrade, list, search, info" >&2; exit 64 ;;
	esac
	EOF
	chmod 755 "$BOOT/bin/pkg"
fi

# ---------------------------------------------------------------------------
# 4. fetch + inject dependency debs (recursively) from the Termux repo
# ---------------------------------------------------------------------------
DEPS="libgc boost brotli bzip2 libarchive libcurl libgit2 liblz4 libseccomp libsodium libsqlite lowdown openssl readline zlib zstd xz-utils"

PKGS="$WORKDIR/Packages-$ARCH"
[ -f "$PKGS" ] || curl -fsSL -o "$PKGS" "$TERMUX_REPO/dists/stable/main/binary-$ARCH/Packages"

# Extract one field for a package from the Packages index.
pkg_field() {
	local pkg="$1" field="$2"
	awk -v p="$pkg" -v f="$field" '
		BEGIN { RS=""; FS="\n" }
		{
			name=""; val=""
			for (i = 1; i <= NF; i++) {
				if ($i ~ /^Package: /) name = substr($i, 10)
				if (index($i, f ": ") == 1) val = substr($i, length(f) + 3)
			}
			if (name == p) { print val; exit }
		}
	' "$PKGS"
}

declare -A SEEN=()

fetch_deb() {
	local pkg="$1"
	[ -n "${SEEN[$pkg]:-}" ] && return 0
	SEEN[$pkg]=1

	local fn deps dest
	fn="$(pkg_field "$pkg" Filename)"
	if [ -z "$fn" ]; then
		echo "error: cannot resolve dependency '$pkg' in the Termux repo" >&2
		return 1
	fi

	dest="$WORKDIR/debs/$(basename "$fn")"
	if [ ! -f "$dest" ]; then
		log "downloading: $pkg"
		curl -fsSL -o "$dest.tmp" "$TERMUX_REPO/$fn" \
			&& mv "$dest.tmp" "$dest" \
			|| { rm -f "$dest.tmp"; return 1; }
	fi
	extract_deb "$dest"

	deps="$(pkg_field "$pkg" Depends)"
	[ -n "$deps" ] || return 0
	# Strip version constraints and alternatives: take the first alternative.
	# Process substitution keeps this loop in the current shell, so recursion
	# updates SEEN and failures abort the script (set -e).
	while IFS= read -r dep; do
		dep="${dep%%|*}"
		dep="${dep%:any}"
		dep="$(printf '%s' "$dep" | sed -E 's/[[:space:]]*\(.*\)[[:space:]]*$//; s/[[:space:]]+$//; s/^[[:space:]]+//')"
		[ -n "$dep" ] || continue
		fetch_deb "$dep"
	done < <(printf '%s\n' "$deps" | tr ',' '\n')
}

log "injecting runtime dependencies: $DEPS"
for dep in $DEPS; do fetch_deb "$dep"; done

# ---------------------------------------------------------------------------
# 5. nix deb (local, or latest CI artifact)
# ---------------------------------------------------------------------------
if [ -z "$NIX_DEB" ]; then
	shopt -s nullglob
	g=( "$WORKDIR"/debs/nix_*_"$ARCH".deb "$SCRIPT_DIR"/nix_*_"$ARCH".deb )
	shopt -u nullglob
	if [ ${#g[@]} -gt 0 ]; then
		NIX_DEB="${g[0]}"
	else
		log "downloading nix deb from latest CI run (needs gh)..."
		run_id=$(gh run list --workflow=termux.yml --branch=master \
			--json databaseId,conclusion --jq '[.[] | select(.conclusion=="success")][0].databaseId')
		gh run download "$run_id" --name "nix-termux-$ARCH" --dir "$WORKDIR/debs"
		NIX_DEB=$(ls "$WORKDIR"/debs/nix_*_"$ARCH".deb)
	fi
fi
log "injecting nix: $NIX_DEB"
extract_deb "$(readlink -f "$NIX_DEB")"

# ---------------------------------------------------------------------------
# 6. runtime layout + nix.conf
# ---------------------------------------------------------------------------
log "initializing nix store/state directories..."
mkdir -p "$BOOT/nix/store" \
	"$BOOT/var/nix/builds" \
	"$BOOT/var/nix/profiles" \
	"$BOOT/var/log/nix" \
	"$BOOT/etc/nix"
if [ ! -f "$BOOT/etc/nix/nix.conf" ]; then
	: > "$BOOT/etc/nix/nix.conf"
fi
# Ensure the settings we need are present without duplicating keys that a
# package-provided nix.conf already has.
ensure_conf() {
	local key="$1" line="$2"
	grep -qE "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$BOOT/etc/nix/nix.conf" \
		|| printf '%s\n' "$line" >> "$BOOT/etc/nix/nix.conf"
}
ensure_conf sandbox "sandbox = false"
ensure_conf substitute "substitute = false"
ensure_conf build-dir "build-dir = $TERMUX_PREFIX/var/nix/builds"
ensure_conf log-dir "log-dir = $TERMUX_PREFIX/var/log/nix"
ensure_conf experimental-features "experimental-features = nix-command flakes"
cat >> "$BOOT/etc/nix/nix.conf" <<-EOF

	# Injected by make-nix-bootstrap.sh: Android has no user namespaces and
	# SELinux blocks chroot/mount, so Nix builds are always unsandboxed.
EOF
chmod 644 "$BOOT/etc/nix/nix.conf"

# ---------------------------------------------------------------------------
# 7. bootstrap stages: one stage that initialises apk *and* nix
# ---------------------------------------------------------------------------
# The stock second stage runs the postinst scripts of every package in the
# bootstrap. Since the nix .deb is extracted instead of being installed with
# dpkg, its postinst never runs, so the database is initialised here instead.
# The apk stage is kept from the apk-tools bootstrap.
log "installing combined apk+nix bootstrap second stage..."
SS_DIR="$BOOT/etc/termux/termux-bootstrap/second-stage"
mkdir -p "$SS_DIR"
cat > "$SS_DIR/termux-bootstrap-second-stage.sh" <<- EOF
	#!$TERMUX_PREFIX/bin/bash
	# apk + nix bootstrap second stage
	# Injected by make-nix-bootstrap.sh.
	PREFIX=$TERMUX_PREFIX
	SELF_DIR="\$(cd "\$(dirname "\$0")" && pwd)"
	# run once: atomic lock via symlink
	ln -s . "\$SELF_DIR/\$(basename "\$0").lock" 2>/dev/null || exit 0
	tmpdir="\$PREFIX/tmp"
	mkdir -p "\$tmpdir"
	chmod 1777 "\$tmpdir" 2>/dev/null || true
	# initialize the apk database (apk is the package manager, apt is gone)
	[ -x "\$PREFIX/bin/apk" ] && "\$PREFIX/bin/apk" add --initdb >/dev/null 2>&1
	# initialize the single-user nix database
	if [ -x "\$PREFIX/bin/nix-store" ] && [ ! -e "\$PREFIX/var/nix/db/db.sqlite" ]; then
		mkdir -p "\$PREFIX/nix/store" \\
			"\$PREFIX/var/nix/builds" \\
			"\$PREFIX/var/nix/profiles" \\
			"\$PREFIX/var/log/nix" 2>/dev/null || true
		"\$PREFIX/bin/nix-store" --init >/dev/null 2>&1 || true
	fi
	exit 0
EOF
chmod 755 "$SS_DIR/termux-bootstrap-second-stage.sh"

# Safety net: if the second stage was skipped (e.g. the prefix was swapped in
# by hand), make sure both databases exist on the next login.
log "installing first-login hook..."
mkdir -p "$BOOT/etc/profile.d"
cat > "$BOOT/etc/profile.d/99-nix-init.sh" <<- EOF
# shellcheck shell=sh
# Injected by make-nix-bootstrap.sh. Initialise the apk and nix databases once,
# since the bootstrap extracts the .debs instead of installing them with dpkg.
[ -x "$TERMUX_PREFIX/bin/apk" ] && [ ! -f "$TERMUX_PREFIX/lib/apk/db/installed" ] \\
	&& "$TERMUX_PREFIX/bin/apk" add --initdb >/dev/null 2>&1
if [ -x "$TERMUX_PREFIX/bin/nix-store" ] && [ ! -e "$TERMUX_PREFIX/var/nix/db/db.sqlite" ]; then
	mkdir -p "$TERMUX_PREFIX/nix/store" \\
		"$TERMUX_PREFIX/var/nix/builds" \\
		"$TERMUX_PREFIX/var/nix/profiles" \\
		"$TERMUX_PREFIX/var/log/nix" 2>/dev/null || true
	"$TERMUX_PREFIX/bin/nix-store" --init >/dev/null 2>&1 || true
fi
EOF
chmod 644 "$BOOT/etc/profile.d/99-nix-init.sh"

# ---------------------------------------------------------------------------
# 8. motd
# ---------------------------------------------------------------------------
if [ -f "$MOTD" ]; then
	log "installing custom motd"
	install -Dm644 "$MOTD" "$BOOT/etc/motd"
fi

# ---------------------------------------------------------------------------
# 9. normalize permissions, regenerate SYMLINKS.txt and rezip
# ---------------------------------------------------------------------------
# The tree is built under umask 077; a bootstrap prefix expects the usual
# 755/644 split (tmp/ keeps its 700 mode, the second stage makes it 1777).
log "normalizing permissions..."
find "$BOOT" -type d ! -path "$BOOT/tmp" -exec chmod 755 {} +
find "$BOOT" -type f -perm -u+x -exec chmod 755 {} +
find "$BOOT" -type f ! -perm -u+x -exec chmod 644 {} +

log "regenerating SYMLINKS.txt..."
(cd "$BOOT" && rm -f SYMLINKS.txt && \
	find . -type l -print0 | sort -z | \
	while IFS= read -r -d '' link; do \
		echo "$(readlink "$link")←$link" >> SYMLINKS.txt; \
		rm -f "$link"; \
	done)

log "creating $OUT..."
rm -f "$OUT"
(cd "$BOOT" && zip -q -r9 "$OUT" ./)

log "done."
echo
echo "== validation =="
unzip -l "$OUT" | grep -E "SYMLINKS|bin/apk$|bin/pkg$|bin/nix$|etc/nix/nix.conf" | head
# apt must be gone
if unzip -l "$OUT" | grep -qE "bin/(apt|apt-get|dpkg|dpkg-deb)$|var/lib/dpkg|etc/apt"; then
	echo "error: apt/dpkg leftovers in the bootstrap" >&2
	exit 1
fi
echo "apt/dpkg stripped OK (apk is the package manager)"
unzip -p "$OUT" SYMLINKS.txt | grep -qE '←\./bin/nix-env$' \
	|| { echo "error: SYMLINKS.txt lacks bin/nix-env" >&2; exit 1; }
unzip -p "$OUT" SYMLINKS.txt | grep -qE '←\./bin/nix-store$' \
	|| { echo "error: SYMLINKS.txt lacks bin/nix-store" >&2; exit 1; }
conf=$(unzip -p "$OUT" etc/nix/nix.conf)
for key in sandbox substitute build-dir experimental-features; do
	printf '%s\n' "$conf" | grep -qE "^[[:space:]]*$key[[:space:]]*=" \
		|| { echo "error: nix.conf lacks $key" >&2; exit 1; }
done
stage=$(unzip -p "$OUT" etc/termux/termux-bootstrap/second-stage/termux-bootstrap-second-stage.sh)
printf '%s\n' "$stage" | grep -q 'apk" add --initdb' \
	|| { echo "error: second stage does not initialise apk" >&2; exit 1; }
printf '%s\n' "$stage" | grep -q 'nix-store" --init' \
	|| { echo "error: second stage does not initialise the nix database" >&2; exit 1; }
echo "apk + nix second stage OK"
echo
echo "Bootstrap ready: $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Install it on a device with:"
echo "  bash packaging/termux/install-nix-bootstrap.sh $OUT"
echo "or flash it with a Termux app build that loads a custom bootstrap zip."
