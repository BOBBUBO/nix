# Nix, natively on Termux

This tree is a patched checkout of **Nix 2.36.0** that compiles and runs
**natively on Termux** (Android) — no proot, no chroot, no custom Android
userspace. `nix`, `nix-store`, `nix-env`, `nix-instantiate`, `nix-build`, the
REPL and the shared libraries are real bionic binaries built with Termux's own
clang toolchain.

Everything is reproducible with three scripts:

| Script | What it does |
|---|---|
| [`packaging/termux/build.sh`](build.sh) | one-shot native build on the device: device checks → deps → configure → build → install → smoke test |
| [`packaging/termux/make-deb.sh`](make-deb.sh) | package a staged native install into a Termux `.deb` |
| [`packaging/termux/make-nix-bootstrap.sh`](make-nix-bootstrap.sh) | build an apt-free Termux bootstrap: apk-tools bootstrap + Nix |
| [`packaging/termux/install-nix-bootstrap.sh`](install-nix-bootstrap.sh) | install that bootstrap on a device (usr/usern swap, no app rebuild) |
| [`packaging/termux/make-release.sh`](make-release.sh) | assemble the release bundle (.deb, bootstrap, tarball, checksums, notes) and publish it |

The complete source diff is in [`packaging/termux/nix-android.patch`](nix-android.patch).

> Verified on: aarch64 (arm64-v8a), Android 13 (API 33), kernel 5.10, Termux
> with bionic, clang 21.1.8, meson 1.12.1, ninja 1.13.2.

---

## What works (verified on-device)

| Command | Result |
|---|---|
| `nix --version` | `nix (Nix) 2.36.0` |
| `nix eval --expr '1 + 2'` | `3` |
| `nix eval nixpkgs#hello.version` | `"2.12.3"` (full nixpkgs evaluation) |
| `nix-instantiate --eval '<nixpkgs>' -A hello.version` | `"2.12.3"` |
| `nix flake metadata github:NixOS/nixpkgs` | fetches via git/tar over TLS |
| `nix-channel --add … && nix-channel --update` | updates, then `<nixpkgs>` evaluates |
| `nix-store --add file` / `nix hash file` / `nix path-info` | store add + hashing |
| `nix-store --dump x \| nix-store --restore y` | NAR dump/restore roundtrip |
| `echo '1 + 2' \| nix repl` | `3` |
| custom derivation build | builder runs, output registered in the store |
| `nix-env --version` | `nix-env (Nix) 2.36.0` |
| `nix-env -f ./packages.nix -i <name>` | installs a self-contained derivation into `~/.nix-profile` |
| `nix-env -q`, `nix-env -e`, `--list-generations`, `--rollback` | profile queries, uninstall and generations work |
| `nix-instantiate --arg` / `--arg-from-stdin` | pass values (incl. from stdin) into attribute-set functions |

Key runtime locations (all under Termux's prefix):

```
$PREFIX/bin/nix, nix-store, nix-env, ...
$PREFIX/nix/store            <- the Nix store
$PREFIX/var/nix              <- state dir (db, gcroots, builds)
~/.local/state/nix/profiles  <- per-user nix-env profile generations (XDG)
$PREFIX/etc/nix/nix.conf     <- generated config (see build.sh)
```

---

## nix-env

`nix-env` is the legacy profile manager and is fully usable on Termux. The
profile lives at `~/.nix-profile` (a symlink into
`~/.local/state/nix/profiles/profile`), so the first command creates it:

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"   # optional

nix-env --version
nix-env -q                    # creates ~/.nix-profile on first run
```

Install a self-contained package (a derivation with an explicit Termux
builder — see the example below), query it, then remove it:

```bash
cat > hello.nix <<'EOF'
{
  hello = builtins.derivation {
    name = "hello";
    system = builtins.currentSystem;      # aarch64-linux thanks to the patches
    builder = "/data/data/com.termux/files/usr/bin/bash";
    args = [ "-c" "/data/data/com.termux/files/usr/bin/mkdir -p $out/bin && echo hello-from-termux > $out/bin/hello" ];
  };
}
EOF

nix-env -f ./hello.nix -i hello     # builds and installs into the profile
nix-env -q                          # hello
ls -l ~/.nix-profile/bin            # profile contents
nix-env --list-generations
nix-env --rollback                  # switch to the previous generation
nix-env -e hello                    # uninstall
```

Do not mix `nix-env` and `nix profile` on the same profile: `nix profile`
stores a `manifest.json`, and `nix-env` deliberately refuses profiles in that
format. Use `nix-env` throughout, or choose a separate `--profile` path for
`nix profile`.

`nix-env -iA nixpkgs.hello` does **not** work: the nixpkgs bootstrap
derivations require a glibc userland (`/bin/sh`, coreutils, the prebuilt
bootstrap tarballs), none of which exist on Android. Nix evaluation, flake
commands, channels and *self-contained* derivations all work; see
[Known limitations](#known-limitations).

---

## Why this works at all

Android *is* Linux: the kernel is a real Linux kernel and `bionic` is a
POSIX-ish libc. Termux provides everything else — a package manager,
compilers, headers, and a userspace rooted at `$PREFIX`. Nix needs three more
things from the platform than the average program:

1. **Be told it's on Linux.** Meson reports the host system as `android`, and
   Nix's build system uses `host_machine.system() == 'linux'` to decide which
   sources to compile (Linux sandbox/chroot code, `NIX_LOCAL_SYSTEM`, landlock
   checks). With the system reported as `android`, those branches were silently
   skipped — Nix 2.36's meson build *cannot* build at all without the
   normalization below.
2. **A few bionic quirks.** Bionic is a lean libc: it has no `sync_file_range`,
   `close_range` or `setdomainname` wrappers, and hides declarations behind
   `__ANDROID_API__` guards even when the kernel supports the syscall. These are
   called via raw `syscall()`.
3. **Deal with Android's SELinux policy.** Android blocks `open("/", O_RDONLY)`
   even for its own apps; Nix's filesystem accessor must fall back to `O_PATH`
   (which is sufficient — it only needs the fd for `*at()` traversal).

## The patches (12 files, ~290 lines)

### Build system — Android is Linux

| File | Change |
|---|---|
| `nix-meson-build-support/deps-lists/meson.build` | **The key fix.** Normalize `host_machine.system() == 'android'` → `'linux'` in `nix_host_system`, which every subproject includes first. Without this, all `== 'linux'` conditionals across the tree evaluate false and Nix can't compile. |
| `nix-meson-build-support/common/meson.build` | disable precompiled headers on Android (`target_machine.system() != 'android'`) and only add `-fpch-instantiate-templates` when PCH is on: the NDK clang (r29, 21.0.0) segfaults in the parser (PCH generation at `nix/util/source-path.hh`) and in eager parse-time template instantiation (`std::optional<...>` members, e.g. in `args.cc`/`archive.cc`). Also skip `-Werror=weak-vtables` for `nix-expr-c` on Android: bdwgc's `gc_cpp.h` defines `gc_cleanup` without an out-of-line key function, which would otherwise break that C API target |
| `src/libstore/meson.build` | use `nix_host_system` for `NIX_LOCAL_SYSTEM` (so the system double is `aarch64-linux`, not `aarch64-android`), the landlock/`is_linux` checks and `subdir('linux')` (chroot derivation builder). |
| `src/libstore/unix/meson.build`, `src/libutil/meson.build`, `src/libutil-tests/meson.build` | same replacement for the remaining `== 'linux'` checks. |
| `src/libcmd/meson.build` | accept Termux's `libedit` pkg-config name (`libedit` flavor). The build uses the GNU readline flavor anyway (see below). |

### bionic: syscalls without wrappers

| File | Change |
|---|---|
| `src/libutil/file-descriptor.cc` | `sync_file_range` → `::syscall(SYS_sync_file_range, …)` under `__ANDROID__` |
| `src/libutil/unix/file-descriptor.cc` | `close_range` → `::syscall(SYS_close_range, …)` under `__ANDROID__` (meson's `has_function` link test passes — the device libc has it — but bionic's headers hide the declaration) |
| `src/libstore/linux/build/linux-derivation-builder.cc` | `setdomainname` → `::syscall(SYS_setdomainname, …)` under `__ANDROID__` |

### Android platform quirks

| File | Change |
|---|---|
| `src/libutil/posix-source-accessor.cc` | root-dir fd: fall back to `open("/", O_PATH \| O_DIRECTORY \| O_CLOEXEC)` on Android when `O_RDONLY` fails with `EACCES`/`EPERM` (SELinux) |
| `src/libstore/filetransfer.cc` | default CA bundle: after the standard paths, also try `$PREFIX/etc/tls/cert.pem` and `$PREFIX/etc/ssl/certs/ca-certificates.crt` on Android (Termux keeps its CA bundle under `$PREFIX`; without this, HTTPS downloads in builds fail with curl error 77) |

### Environment fixes (outside the tree)

- **BLAKE3** is not packaged in Termux — `build.sh` builds `libblake3` from
  source (with `-fPIC`, since Nix links it into `libnixutil.so`) and installs
  it into `$PREFIX`. Nix's `nix-hash`/NAR hashing requires it.
- Termux's **libgc** ships without the C++ interface headers Nix's `libexpr`
  needs — `build.sh` fetches `gc_cpp.h` and `gc_allocator.h` from bdwgc
  v8.2.12 into `$PREFIX/include/gc/`.
- **readline flavor**: Termux's `libedit` lacks `editline.h`/`rl_set_complete_func`;
  the build uses GNU `readline` (`-Dlibcmd:readline-flavor=readline`).
- meson can't find Boost in Termux's prefix by itself — configure with
  `BOOST_INCLUDEDIR=$PREFIX/include BOOST_LIBRARYDIR=$PREFIX/lib`.

---

## Device support

### Supported

Any **Android device that runs Termux** (bionic, clang toolchain, `$PREFIX`
userspace), single-user (non-rooted) operation. Tested on **aarch64, Android
13, kernel 5.10**; the same patches apply verbatim to other Termux-supported
ABIs (see below). Other Android releases are untested.

Why it works: Android provides a real Linux kernel and bionic exposes the
syscalls Nix needs (via the `syscall()` fallbacks above); Termux provides the
compiler and libraries. Nix runs in **local (single-user) mode** with the store
at `$PREFIX/nix/store` — no daemon, no root, no namespaces required.

Constraints that *are* required:

- **Internal storage.** The store must live on `/data` (ext4/f2fs). External/SD
  storage is FUSE (`/storage/emulated` etc.) and cannot do the hardlinks, chown
  and xattrs the store needs.
- **Android 7+ (API 24+).** That's Termux's own minimum, and Nix 2.36 needs a
  C++23 toolchain, which Termux ships on all supported devices.
- **Plain Termux, not Termux in a container/VM.** The patches assume `$PREFIX`
  semantics (e.g. CA bundle location, `$PREFIX` env var).

### Likely works, untested

- **armv7 (32-bit ARM), x86_64, x86, riscv64**: Nix is architecture-agnostic and
  the patches don't touch arch-specific code. Notable difference: `libcpuid`
  (x86 CPU detection, used for `nix build --cores` tuning) is not available in
  Termux; it's an optional dependency and Nix builds fine without it.
- **Termux with the glibc repo** (`pkg install glibc` prefix): untested. The
  `syscall()` fallbacks would be unnecessary there but harmless; the bionic API
  guard issue disappears.

### Not supported, and why

| Setup | Why not |
|---|---|
| **iOS, Windows, macOS, Linux distros on other prefixes** | Not Linux/not bionic; these patches are specific to the Android/Termux deltas. |
| **Android devices where Termux can't install** (Android < 7, or vendor-locked devices) | No clang/headers/userspace available; nothing to build against. |
| **Store on SD card / external storage** | FUSE filesystems lack hardlink/chown semantics the Nix store requires. |
| **Rooted devices hoping for sandboxed builds** | Android kernels are built *without* user namespaces, and even where present, SELinux blocks unprivileged `userns_create`; `mount`/`chroot` are likewise blocked. There is no way to get Nix's build sandbox on Android. (This affects only *sandboxing* — everything else works as root or not.) |
| **Stock nixpkgs package builds** | nixpkgs bootstrap derivations expect a full Linux userspace (`/bin/sh` is mksh on Android, no coreutils environment, glibc bootstrap tarballs, etc.) and typically fail during bootstrap. Simple/self-contained derivations build fine. See Limitations. |
| **Binary-cache substitution from cache.nixos.org** | The cache serves store paths under `/nix/store`; this store lives at `$PREFIX/nix/store`, so paths don't match. Relocating the store to `/nix/store` needs root. |

---

## Replicate it

```bash
bash packaging/termux/build.sh --check   # device check only, makes no changes
bash packaging/termux/build.sh           # checks → deps → build → install → smoke test
```

The script first checks the device (architecture, Android version, kernel, disk
space, store filesystem, temp dir) and prints warnings or aborts when something
is missing or unsupported, then installs packages, builds BLAKE3 if necessary,
fetches the missing libgc headers, installs Nix into `$PREFIX`, sets up the
store/state dirs and `nix.conf`, and smoke-tests `nix`, `nix eval` and
`nix-env`.

Manual equivalent:

```bash
# 1. dependencies (build + runtime)
pkg install -y ninja nlohmann-json boost boost-headers libseccomp libsodium \
    libgc libgit2 lowdown libedit readline libarchive libcurl libsqlite \
    openssl brotli zstd xz-utils liblz4 bison flex clang cmake git python pip \
    pkg-config busybox toml11

python -m pip install --break-system-packages --upgrade meson

# 2. BLAKE3 (not in Termux repos; -fPIC because it is linked into libnixutil.so)
git clone --depth 1 https://github.com/BLAKE3-team/BLAKE3
cmake -S BLAKE3/c -B BLAKE3/c/build -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=$PREFIX
cmake --build BLAKE3/c/build -j$(nproc) && cmake --install BLAKE3/c/build

# 3. missing libgc C++ headers (Termux package omission)
curl -sL https://raw.githubusercontent.com/ivmai/bdwgc/v8.2.12/include/gc_cpp.h \
    -o $PREFIX/include/gc/gc_cpp.h
curl -sL https://raw.githubusercontent.com/ivmai/bdwgc/v8.2.12/include/gc_allocator.h \
    -o $PREFIX/include/gc/gc_allocator.h

# 4. configure & build (in this repo, with the patches applied)
export BOOST_INCLUDEDIR=$PREFIX/include BOOST_LIBRARYDIR=$PREFIX/lib
meson setup build . \
    --prefix=$PREFIX \
    --buildtype=release \
    -Dunit-tests=false -Dfunctional-tests=false -Ddoc-gen=false \
    -Djson-schema-checks=false \
    -Dnix-store:seccomp-sandboxing=auto \
    -Dlibcmd:readline-flavor=readline \
    -Dlibstore:store-dir=$PREFIX/nix/store \
    -Dlibstore:log-dir=$PREFIX/var/log/nix \
    --localstatedir=$PREFIX/var --sysconfdir=$PREFIX/etc
ninja -C build && ninja -C build install

# 5. first-run setup
mkdir -p $PREFIX/nix/store $PREFIX/var/nix/builds $PREFIX/var/nix/profiles \
    $PREFIX/var/log/nix $PREFIX/etc/nix
cat > $PREFIX/etc/nix/nix.conf <<NIXCONF
sandbox = false
substitute = false
build-dir = $PREFIX/var/nix/builds
log-dir = $PREFIX/var/log/nix
experimental-features = nix-command flakes
NIXCONF
$PREFIX/bin/nix-store --init
```

Notes:

- `build.sh --destdir DIR` stages the install into `DIR` instead of `$PREFIX`
  (useful for packaging without touching the running prefix).
- If you change a subproject option later (`meson configure -Dlibcmd:...`),
  `touch` that subproject's `meson.build` so its generated config header
  (`cmd-config-private.hh`) is regenerated — otherwise the change silently
  doesn't take effect.
- `nix-command`/`flakes` are experimental: `export NIX_CONFIG="experimental-features = nix-command flakes"`.
  The generated `nix.conf` enables them already.
- `/tmp` is not writable on Android; use `$PREFIX/tmp`. `nix.conf` sets
  `build-dir` to `$PREFIX/var/nix/builds` for this reason.

---

## Packaging for Termux

### GitHub Actions (`.github/workflows/termux.yml`)

The workflow compiles Nix **for** Termux, packages it for Termux's package
manager, and (on tags) uploads the artifacts as a GitHub release. It does *not*
build on-device: it cross-compiles on a GitHub-hosted runner inside Termux's
official build container (`ghcr.io/termux/package-builder`, the same image
Termux's own CI uses), so a full Android toolchain and all Termux libraries are
available. The result is the same native bionic binary — just produced faster
than on a phone.

How it works:

1. Checks out this repo (patched source) and `termux/termux-packages`.
2. Overlays the tree into `termux-packages/packages/nix/src` together with the
   recipe [`termux-packages/nix/build.sh`](termux-packages/nix/build.sh).
3. Runs `./scripts/run-docker.sh ./build-package.sh -I -C -a aarch64
   --format debian -o output packages/nix` — the same invocation Termux's own
   CI uses. `-I` downloads dependency packages
   from the official Termux repositories (boost, libgc, libgit2, lowdown,
   toml11, nlohmann-json, libseccomp, libsodium, readline, ...) instead of
   rebuilding them.
4. Verifies that the `.deb` contains `usr/bin/nix`, `nix-env`, `nix-store` and
   `nix-instantiate`, extracts the binaries into a standalone tarball, and
   uploads `nix_2.36.0-1_aarch64.deb` + tarball + `SHA256SUMS`.

Triggers:

- **Push a tag** `v2.36.0` (or any `v*`): builds and creates a release named
  after the tag.
- **Manual** (`Actions` → *Termux package* → *Run workflow*): pick an
  architecture and optionally publish the prerelease named `nightly`.

Recipe specifics (same fixes as the on-device build, adapted to cross):

- `libblake3` is not in Termux repos → built inside the recipe as a **static,
  position-independent** library, so the shipped nix binaries are
  self-contained.
- Termux's `libgc` lacks `gc_cpp.h`/`gc_allocator.h` → fetched from bdwgc
  v8.2.12 in the recipe.
- meson Boost detection is pointed at `$PREFIX` via
  `BOOST_INCLUDEDIR`/`BOOST_LIBRARYDIR`; `termux_setup_cmake` provides cmake
  (meson's toml11/Boost checks may use it).
- The `nix_host_system` normalization (patch #1) makes the cross build see
  `system = 'android'` as Linux, so the resulting binary reports
  `aarch64-linux` as its system double.
- Compiled paths: store `$PREFIX/nix/store`, state `$PREFIX/var/nix`,
  config `$PREFIX/etc/nix` — identical to the on-device build.

### On-device `.deb`

To package the binary you just built natively (no Docker, no cross-compiler):

```bash
bash packaging/termux/build.sh --destdir "$PREFIX/tmp/nix-stage"
bash packaging/termux/make-deb.sh "$PREFIX/tmp/nix-stage"
# -> nix_2.36.0-1_aarch64.deb
pkg install ./nix_2.36.0-1_aarch64.deb
```

### Installing the CI package on a device

```bash
pkg install ./nix_*.deb
# or
apt install ./nix_*.deb
```

All runtime dependencies (`Depends` of the `.deb`) come from the standard
Termux repositories. Alternatively, extract the binaries tarball into `$PREFIX`:

```bash
tar -C $PREFIX -xzf nix-*-termux-aarch64-bin.tar.gz
mkdir -p $PREFIX/nix/store $PREFIX/var/nix/builds $PREFIX/var/log/nix
$PREFIX/bin/nix-store --init
```

### Termux bootstrap injection (apt-free, apk + Nix)

[`make-nix-bootstrap.sh`](make-nix-bootstrap.sh) builds
`nix-bootstrap-<arch>.zip`: a Termux bootstrap that has **no apt/dpkg at all**
and ships **Nix** on top of the apk-tools bootstrap:

| layer | what it provides |
|---|---|
| apk-tools bootstrap (base) | stock Termux bootstrap with the apt/dpkg stack stripped, `apk` as the package manager, an apk-backed `pkg` shim, apk repositories/keys and an apk-based bootstrap second stage |
| Nix (injected) | `nix`, `nix-env`, `nix-store`, ... plus the runtime libraries they need, the store/state layout and a preconfigured `nix.conf` |
| combined second stage | one bootstrap stage that initialises **both** the apk database and the single-user Nix database |

The base bootstrap is reused from a local `apk-tools` checkout when there is
one (`../apk-tools/make-apk-bootstrap.sh` is run for you); otherwise the
published `apk-bootstrap-<arch>.zip` is downloaded.

```bash
cd packaging/termux
./make-nix-bootstrap.sh aarch64                    # fetch the latest CI .deb
./make-nix-bootstrap.sh aarch64 ./nix_*.deb        # or use a local .deb
./make-nix-bootstrap.sh aarch64 --apk-bootstrap ./apk-bootstrap-aarch64.zip
```

Options: `--apk-bootstrap FILE|URL` (use a specific apk base),
`--apk-tools-deb FILE` (inject apk when the base has none) and
`--refresh-base` (rebuild the cached apk bootstrap).

#### Installing it on a device

[`install-nix-bootstrap.sh`](install-nix-bootstrap.sh) installs the zip on a
running device without rebuilding the Termux app, using the same
`usr` -> `usr-n` swap as the apk-tools installer (and reusing it when
`apk-tools/install-apk-bootstrap.sh` is available):

```bash
# 1. in a normal Termux session
bash packaging/termux/install-nix-bootstrap.sh packaging/termux/nix-bootstrap-aarch64.zip
# 2. restart Termux in failsafe (recovery) mode, then
/data/data/com.termux/files/install-nix-bootstrap.sh --finalize
# 3. exit failsafe, start Termux normally
```

The old prefix is kept as `usr.old` until you delete it.

#### What replaces apt

`apt`/`dpkg` are gone, `apk` is the package manager and `pkg` is a thin shim
over it (`pkg install` -> `apk add`, `pkg update` -> `apk update`, ...). Termux
packages are available as repacked `.apk` files in the apk repositories, so
`apk add <package>` still installs them. Nix is the second package manager and
only manages Nix store paths - it cannot install Termux packages.

Test the resulting zip on a secondary device (or in a throwaway prefix) before
flashing it over a working install.

### Releasing

`make-release.sh` bundles the artifacts and writes the installation notes:

```bash
# 1. build and stage the native install, then package it
bash packaging/termux/build.sh --destdir "$PREFIX/tmp/nix-stage"
bash packaging/termux/make-deb.sh "$PREFIX/tmp/nix-stage"

# 2. build the apt-free bootstrap around that .deb
bash packaging/termux/make-nix-bootstrap.sh aarch64 \
    "$PREFIX/tmp/nix-stage/nix_2.36.0-1_aarch64.deb"

# 3. assemble the release bundle (dist/)
bash packaging/termux/make-release.sh \
    --stage "$PREFIX/tmp/nix-stage" \
    --deb "$PREFIX/tmp/nix-stage/nix_2.36.0-1_aarch64.deb" \
    --bootstrap packaging/termux/nix-bootstrap-aarch64.zip

# 4. publish it: tag the current commit, push the tag and create the
#    GitHub release with the checksums and notes
bash packaging/termux/make-release.sh ... --publish termux-2.36.0-1
```

Tags starting with `v` also trigger the CI release build, so the on-device
script uses a `termux-` prefix. Use a `v*` tag when you want CI to build and
publish the artifacts instead.

`dist/` then contains:

| file | what it is |
|---|---|
| `nix_2.36.0-1_aarch64.deb` | Termux package (`pkg install ./nix_*.deb`) |
| `nix-bootstrap-aarch64.zip` | apt-free bootstrap: `apk` + Nix |
| `nix-2.36.0-termux-aarch64-bin.tar.gz` | binaries only, unpack into `$PREFIX` |
| `SHA256SUMS` | checksums |
| `RELEASE-NOTES.md` | how to install the deb and the bootstrap |

The release notes are the user-facing installation instructions:

```bash
# .deb on an existing Termux install
pkg install ./nix_2.36.0-1_aarch64.deb

# apt-free bootstrap on a running device
bash install-nix-bootstrap.sh nix-bootstrap-aarch64.zip
# then in failsafe mode:
/data/data/com.termux/files/install-nix-bootstrap.sh --finalize
```

---

## Example commands

```bash
export NIX_CONFIG="experimental-features = nix-command flakes"

nix --version                                   # nix (Nix) 2.36.0
nix eval --expr '1 + 2'                         # 3
nix-instantiate --eval --expr '{ x }: x + 1' --arg x 42   # 43
nix eval nixpkgs#hello.version                  # "2.12.3" (needs flakes)
nix-instantiate --eval '<nixpkgs>' -A hello.version

nix flake metadata github:NixOS/nixpkgs         # network fetch via git+tar

nix-channel --add https://nixos.org/channels/nixpkgs-unstable
nix-channel --update
nix-instantiate --eval '<nixpkgs>' -A hello.version

echo 'hello' > hi.txt
nix-store --add hi.txt                          # .../nix/store/xxxx-hi.txt
nix hash file hi.txt                            # sha256
nix-store --dump hi.txt | nix-store --restore hi2.txt   # NAR roundtrip

echo '1 + 2' | nix repl                         # 3

# nix-env: install a self-contained package into the user profile
nix-env -f ./hello.nix -i hello
nix-env -q                                      # hello
nix-env -e hello

# pass stdin into a function (JSON example)
echo '{"a": 1}' | nix-instantiate --eval \
    --expr '{ json }: builtins.fromJSON json' --arg-from-stdin json
# -> { a = 1; }

# build a derivation with a Termux builder (sandbox auto-disabled)
nix build --impure --expr 'builtins.derivation {
  name = "termux-hello";
  system = "aarch64-linux";
  builder = "/data/data/com.termux/files/usr/bin/bash";
  args = [ "-c" "echo hello-from-termux > $out" ];
}' --no-link
```

---

## Known limitations

- **No build sandbox.** Android kernels lack user namespaces and SELinux blocks
  chroot/mount. Nix notices at runtime and auto-disables sandboxing with a
  warning (`sandbox-fallback`); `sandbox = false` is pre-set in `nix.conf`.
  Builds run as your user, unsandboxed.
- **No binary-cache substitution.** `cache.nixos.org` serves store paths under
  `/nix/store`, so it refuses this store's prefix (`$PREFIX/nix/store`). If you
  relocate the store to `/nix/store` (root), substitution works again.
- **Stock nixpkgs package builds generally fail.** The nixpkgs bootstrap chain
  assumes a conventional Linux userspace (`/bin/sh` resolves to Android's mksh,
  no coreutils PATH, glibc bootstrap binaries, etc.), so deep package builds stop
  early in bootstrap. Self-contained derivations (as in the example above) build
  and register correctly.
- **nix-env cannot install Termux packages.** Nix store paths live under
  `$PREFIX/nix/store` and are self-contained; Termux packages are installed by
  the system package manager. In a normal Termux install that is `pkg`/`apt`;
  in the Nix bootstrap (which has no apt/dpkg) it is `apk`, with `pkg` as a
  shim over it. The two package managers coexist happily.
- **`/dev/stdin` with a *pipe*** (`echo x | nix-instantiate --eval /dev/stdin`)
  fails with `path '/proc/<pid>/fd/pipe:[…]' does not exist` — this is identical
  to Linux (the magic link doesn't resolve for pipes, see `proc_pid_fd(5)`).
  Use `--arg-from-stdin` or a real file path.
- **Performance**: on-device nixpkgs evaluation and compilation are slower than
  on a desktop, though evaluation results are cached in `$PREFIX/var/nix/db`.
- **Channel evaluation** (`nix-env -qa '*'`) works but is slow (minutes) — the
  first full nixpkgs evaluation has to happen on-device.

## Layout

```
packaging/termux/
├── build.sh                       # one-shot on-device build: checks → deps → build → install → smoke test
├── make-deb.sh                    # package a staged native install into a Termux .deb
├── make-nix-bootstrap.sh          # build the apt-free bootstrap: apk base + Nix
├── install-nix-bootstrap.sh       # device-side installer (usr -> usr-n swap)
├── make-release.sh                # assemble/publish the release bundle
├── motd                           # MOTD for the injected bootstrap
├── nix-android.patch              # the full source diff
├── termux-packages/nix/build.sh   # recipe overlay for termux/termux-packages
└── README.md                      # this file

.github/workflows/termux.yml      # CI: build the .deb in Termux's package-builder, publish releases
```

The patches are applied to the tree; the patch file is generated with
`git diff` and is kept in sync with the working tree.
