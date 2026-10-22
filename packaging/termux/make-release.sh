#!/bin/bash
# make-release.sh -- assemble the Termux release artifacts and (optionally)
# publish them as a GitHub release.
#
# Inputs:
#   * the staged native install produced by `build.sh --destdir DIR`
#   * the .deb produced by `make-deb.sh`
#   * the bootstrap zip produced by `make-nix-bootstrap.sh`
#
# Outputs (in dist/):
#   nix_<version>-<rev>_<arch>.deb            Termux package
#   nix-bootstrap-<arch>.zip                  apt-free bootstrap (apk + Nix)
#   nix-<version>-termux-<arch>-bin.tar.gz    unpack into $PREFIX
#   SHA256SUMS                                checksums
#   RELEASE-NOTES.md                          how to install the deb / bootstrap
#
# Usage:
#   bash packaging/termux/make-release.sh \
#       --stage "$PREFIX/tmp/nix-stage" \
#       --deb "$PREFIX/tmp/nix-stage/out/nix_2.36.0-1_aarch64.deb" \
#       --bootstrap packaging/termux/nix-bootstrap-aarch64.zip
#
#   ... --publish v2.36.0-termux.1     # also push a GitHub release
set -eu

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

ARCH="aarch64"
VERSION=""
REVISION="1"
STAGE=""
DEB=""
BOOTSTRAP=""
PUBLISH=""
DIST="$REPO_DIR/dist"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "[*] $*"; }

usage() {
	cat <<EOF
usage: make-release.sh --stage DIR --deb FILE [--bootstrap FILE] [options]

  --stage DIR       staged native install (build.sh --destdir DIR)
  --deb FILE        the .deb to publish
  --bootstrap FILE  the bootstrap zip to publish
  --version V       release version (default: from the .deb name)
  --revision N      package revision (default: 1)
  --arch ARCH       target architecture (default: aarch64)
  --publish TAG     create a GitHub release with this tag
  --dist DIR        output directory (default: $DIST)
  -h, --help        this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--stage) shift; STAGE="$1" ;;
		--deb) shift; DEB="$1" ;;
		--bootstrap) shift; BOOTSTRAP="$1" ;;
		--version) shift; VERSION="$1" ;;
		--revision) shift; REVISION="$1" ;;
		--arch) shift; ARCH="$1" ;;
		--publish) shift; PUBLISH="$1" ;;
		--dist) shift; DIST="$1" ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option '$1' (try --help)" ;;
	esac
	shift
done

[ -n "$DEB" ] || die "--deb is required"
[ -f "$DEB" ] || die "no such deb: $DEB"
[ -n "$STAGE" ] || die "--stage is required"
[ -d "$STAGE" ] || die "no such stage directory: $STAGE"
if [ -z "$VERSION" ]; then
	VERSION="$(basename "$DEB" | sed -E 's/^nix_//; s/_[a-z0-9_]+\.deb$//')"
	# the deb name already carries the revision (2.36.0-1)
	REVISION=""
fi
FULL_VERSION="$VERSION${REVISION:+-$REVISION}"

rm -rf "$DIST"
mkdir -p "$DIST"

log "collecting artifacts..."
cp "$DEB" "$DIST/nix_${FULL_VERSION}_${ARCH}.deb"
if [ -n "$BOOTSTRAP" ]; then
	[ -f "$BOOTSTRAP" ] || die "no such bootstrap: $BOOTSTRAP"
	cp "$BOOTSTRAP" "$DIST/nix-bootstrap-${ARCH}.zip"
fi

# Standalone binaries: the contents of the prefix, so it can be unpacked into
# $PREFIX on a device that has no package manager for it.
TARBALL="$DIST/nix-${FULL_VERSION}-termux-${ARCH}-bin.tar.gz"
STAGED_PREFIX="$STAGE${PREFIX#/}"
if [ -d "$STAGED_PREFIX" ]; then
	log "creating binaries tarball..."
	tar -C "$STAGED_PREFIX" -czf "$TARBALL" .
else
	log "warning: $STAGED_PREFIX not found, skipping the binaries tarball"
fi

log "writing release notes..."
cat > "$DIST/RELEASE-NOTES.md" <<EOF
# Nix $VERSION for Termux

Native bionic build of Nix for Termux/Android (no proot, no chroot, no root).
Store at \`$PREFIX/nix/store\`, state at \`$PREFIX/var/nix\`, config at
\`$PREFIX/etc/nix/nix.conf\`.

## Install the .deb (existing Termux install)

\`\`\`bash
# download the .deb, then:
pkg install ./nix_${FULL_VERSION}_${ARCH}.deb
# or, with apt:
apt install ./nix_${FULL_VERSION}_${ARCH}.deb
\`\`\`

The package installs \`nix\`, \`nix-env\`, \`nix-store\`, ... into \`$PREFIX/bin\`
and creates the store/state directories and \`nix.conf\` in its post-install
script. Verify with:

\`\`\`bash
nix --version
nix eval --expr '1 + 2'
nix-env -q
\`\`\`

Alternatively unpack the binaries tarball into the prefix (no package manager
involved):

\`\`\`bash
tar -C $PREFIX -xzf nix-${FULL_VERSION}-termux-${ARCH}-bin.tar.gz
mkdir -p $PREFIX/nix/store $PREFIX/var/nix/builds $PREFIX/var/log/nix
$PREFIX/bin/nix-store --init
\`\`\`

## Install the bootstrap (apt-free Termux)

\`nix-bootstrap-${ARCH}.zip\` is a complete Termux bootstrap **without
apt/dpkg**: \`apk\` is the package manager and Nix is added next to it.

Flash it with a Termux app build that loads a custom bootstrap zip, or
install it on a running device without rebuilding the app:

\`\`\`bash
# 1. in a normal Termux session
bash install-nix-bootstrap.sh nix-bootstrap-${ARCH}.zip
# 2. restart Termux in failsafe (recovery) mode, then
/data/data/com.termux/files/install-nix-bootstrap.sh --finalize
# 3. exit failsafe and start Termux normally
\`\`\`

The bootstrap's second stage initialises both the apk and the Nix database.
The previous prefix is kept as \`usr.old\` until you delete it.

## Notes and limitations

- Android has no user namespaces and SELinux blocks chroot/mount, so builds
  always run unsandboxed (\`sandbox = false\` is pre-set in \`nix.conf\`).
- \`cache.nixos.org\` serves paths under \`/nix/store\` and cannot match this
  store, so binary-cache substitution is disabled (\`substitute = false\`).
- Stock nixpkgs packages cannot bootstrap on Android; Nix is useful for
  self-contained derivations and Nix store paths.
- \`pkg\` in the bootstrap is a shim over \`apk\`; Termux packages are
  available as repacked \`.apk\` files in the apk repositories.

See \`packaging/termux/README.md\` in the Nix source tree for the full
documentation.
EOF

log "computing checksums..."
(cd "$DIST" && sha256sum nix_*.deb nix-*.tar.gz nix-bootstrap-*.zip > SHA256SUMS 2>/dev/null || true)
(cd "$DIST" && sha256sum RELEASE-NOTES.md >> SHA256SUMS)

log "done. artifacts in $DIST:"
ls -lh "$DIST"

if [ -n "$PUBLISH" ]; then
	command -v gh >/dev/null || die "gh is required for --publish"
	log "publishing GitHub release $PUBLISH ..."
	gh release create "$PUBLISH" \
		--title "Nix $VERSION for Termux" \
		--notes-file "$DIST/RELEASE-NOTES.md" \
		"$DIST"/nix_*.deb "$DIST"/nix-bootstrap-*.zip "$DIST"/nix-*.tar.gz "$DIST"/SHA256SUMS
	log "published: https://github.com/$(gh repo view --json nameWithOwner -q .nameWithOwner)/releases/tag/$PUBLISH"
fi
