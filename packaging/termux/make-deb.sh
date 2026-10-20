#!/data/data/com.termux/files/usr/bin/bash
#
# Package a native Termux install of Nix into a Termux .deb.
#
# Typical use: stage an install on-device, then package it:
#
#   bash packaging/termux/build.sh --destdir "$PREFIX/tmp/nix-stage"
#   bash packaging/termux/make-deb.sh "$PREFIX/tmp/nix-stage"
#
# The resulting nix_<version>_<arch>.deb installs with `pkg install ./...`.
#
# Usage:
#   make-deb.sh [--destdir DIR] [--version V] [--revision N] [--out DIR] [STAGE]
#
# STAGE (or --destdir) is the DESTDIR used for `ninja install`, i.e. it
# contains data/data/com.termux/files/usr/... and DEBIAN/ is created inside.

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

STAGE=""
VERSION="$(cat "$REPO_DIR/.version" 2>/dev/null || echo 2.36.0)"
REVISION="1"
OUTDIR="$(pwd)"
ARCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --destdir) shift; STAGE="$1" ;;
        --version) shift; VERSION="$1" ;;
        --revision) shift; REVISION="$1" ;;
        --out) shift; OUTDIR="$1" ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        -*) echo "unknown option: $1" >&2; exit 2 ;;
        *) STAGE="$1" ;;
    esac
    shift
done

[ -n "$STAGE" ] || { echo "usage: make-deb.sh [--destdir DIR] [STAGE]" >&2; exit 2; }
[ -d "$STAGE" ] || { echo "stage directory not found: $STAGE" >&2; exit 1; }
command -v dpkg-deb >/dev/null || { echo "dpkg-deb not found (pkg install dpkg)" >&2; exit 1; }

case "$(uname -m)" in
    aarch64|arm64) ARCH=aarch64 ;;
    armv7l|armv8l|armv6l) ARCH=arm ;;
    i686|i386|x86) ARCH=i686 ;;
    x86_64|amd64) ARCH=x86_64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BIN="$STAGE${PREFIX#}/bin/nix"
[ -f "$BIN" ] || { echo "no nix binary at expected path: $BIN" >&2; exit 1; }

# Runtime dependencies: same set as the termux-packages recipe, so the .deb
# can be built on-device without termux-packages.
DEPENDS="libgc, boost, brotli, bzip2, libarchive, libcurl, libgit2, liblz4, libseccomp, libsodium, libsqlite, lowdown, openssl, readline, zlib, zstd, xz-utils"

# Normalize permissions: on-device builds run under umask 077, which would
# otherwise ship 700 directories / 600 files. Termux packages use the usual
# 755/644 split.
find "$STAGE" -type f -perm -u+x -exec chmod 755 {} +
find "$STAGE" -type f ! -perm -u+x -exec chmod 644 {} +

STAGE_PREFIX="$STAGE${PREFIX#}"

# `build.sh --destdir` deliberately skips setup_runtime(), so the staged tree
# has no nix.conf. Generate the same config the on-device installer would.
mkdir -p "$STAGE_PREFIX/etc/nix"
if [ ! -f "$STAGE_PREFIX/etc/nix/nix.conf" ]; then
    cat > "$STAGE_PREFIX/etc/nix/nix.conf" <<EOF
# Native Termux build of Nix.
# Android has no user namespaces and SELinux blocks chroot/mount, so builds
# always run unsandboxed.
sandbox = false
# cache.nixos.org paths live under /nix/store and cannot match this store's
# $PREFIX/nix/store prefix.
substitute = false
build-dir = $PREFIX/var/nix/builds
log-dir = $PREFIX/var/log/nix
experimental-features = nix-command flakes
EOF
    chmod 644 "$STAGE_PREFIX/etc/nix/nix.conf"
fi

# Also fix directories created above under a restrictive umask.
find "$STAGE" -type d -exec chmod 755 {} +

# Debian control files must be owned by root; --root-owner-group makes
# dpkg-deb produce that without running as root.
DEBIAN="$STAGE/DEBIAN"
rm -rf "$DEBIAN"
mkdir -p "$DEBIAN"
# dpkg-deb insists on a world-readable control directory; under Termux's
# umask 077 (home directory 700) mkdir would otherwise produce 700.
chmod 755 "$DEBIAN"

installed_size="$(du -sk "$STAGE" | awk '{print $1}')"

cat > "$DEBIAN/control" <<EOF
Package: nix
Version: ${VERSION}-${REVISION}
Architecture: $ARCH
Maintainer: @termux-nix-native
Installed-Size: $installed_size
Depends: $DEPENDS
Section: utils
Priority: optional
Homepage: https://nixos.org/
Description: Nix, the purely functional package manager (native Termux build)
 Nix built natively against bionic using Termux's clang toolchain. Runs
 single-user with the store at \$PREFIX/nix/store; no daemon and no root
 required. Build sandboxing is unavailable on Android (no user namespaces,
 SELinux blocks chroot/mount), so builds are unsandboxed. Stock nixpkgs
 cannot bootstrap on Android; self-contained derivations do build.
EOF
chmod 644 "$DEBIAN/control"

# Make nix.conf a dpkg conffile so local edits survive upgrades.
if [ -e "$STAGE${PREFIX#}/etc/nix/nix.conf" ]; then
	printf '%s\n' "$PREFIX/etc/nix/nix.conf" > "$DEBIAN/conffiles"
	chmod 644 "$DEBIAN/conffiles"
fi

cat > "$DEBIAN/postinst" <<EOF
#!$PREFIX/bin/sh
# Create single-user store/state directories and initialise the Nix DB.
set -e
mkdir -p "$PREFIX/nix/store" "$PREFIX/var/nix/builds" \\
	"$PREFIX/var/nix/profiles" "$PREFIX/var/log/nix"
[ -e "$PREFIX/var/nix/db/db.sqlite" ] || \\
	"$PREFIX/bin/nix-store" --init >/dev/null 2>&1 || true
exit 0
EOF
chmod 755 "$DEBIAN/postinst"

mkdir -p "$OUTDIR"
DEB="$OUTDIR/nix_${VERSION}-${REVISION}_${ARCH}.deb"
rm -f "$DEB"
dpkg-deb --build --root-owner-group "$STAGE" "$DEB"

echo
echo "Package ready: $DEB"
dpkg-deb -I "$DEB" | sed -n '1,25p'
echo
echo "Install on a Termux device with:"
echo "  pkg install $(readlink -f "$DEB")"
