#!/bin/sh
# install-nix-bootstrap.sh — install the Nix bootstrap on a device without
# rebuilding the Termux app.
#
# The Nix bootstrap is the apk-tools bootstrap (stock Termux bootstrap minus
# apt/dpkg, with `apk` as the package manager) plus Nix. This script installs
# it the same way the apk-tools installer installs its bootstrap: the zip is
# extracted to usr-n/, the symlinks are recreated from SYMLINKS.txt, and the
# prefix is swapped from failsafe mode, where it can be replaced safely.
#
# Usage (on the device):
#   # 1. in a normal Termux session:
#   ./install-nix-bootstrap.sh [bootstrap-zip-or-url]
#   # 2. restart Termux into failsafe (recovery) mode, then:
#   /data/data/com.termux/files/install-nix-bootstrap.sh --finalize
#   # 3. exit failsafe, start Termux normally
#
# When the apk-tools checkout is available next to this script, its installer
# is reused for the generic work (extraction, symlinks, prefix swap); the
# Nix-specific database initialisation is always done here.
#
# Environment:
#   FILES_OVERRIDE   use another prefix root (for testing)
#   APK_INSTALLER    path to apk-tools' install-apk-bootstrap.sh to reuse
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")"

FILES="${FILES_OVERRIDE:-/data/data/com.termux/files}"
USR="$FILES/usr"
USRN="$FILES/usr-n"
# Where a published nix bootstrap can be fetched from (optional).
BOOTSTRAP_URL_BASE="${NIX_BOOTSTRAP_URL_BASE:-}"

die() { echo "error: $*" >&2; exit 1; }

case "$(uname -m)" in
	aarch64|arm64) ARCH=aarch64 ;;
	armv7*|armv8*|armhf) ARCH=arm ;;
	i686|x86) ARCH=i686 ;;
	x86_64|amd64) ARCH=x86_64 ;;
	*) die "unsupported arch: $(uname -m)" ;;
esac

# The apk-tools installer, when it is around, does the generic work.
APK_INSTALLER="${APK_INSTALLER:-}"
if [ -z "$APK_INSTALLER" ] && [ -x "$REPO_DIR/apk-tools/install-apk-bootstrap.sh" ]; then
	APK_INSTALLER="$REPO_DIR/apk-tools/install-apk-bootstrap.sh"
fi

init_nix() {
	# Initialise the single-user Nix database (the nix .deb is extracted, so
	# its postinst never ran).
	[ -x "$USR/bin/nix-store" ] || return 0
	mkdir -p "$USR/nix/store" "$USR/var/nix/builds" "$USR/var/nix/profiles" \
		"$USR/var/log/nix" 2>/dev/null || true
	if [ ! -e "$USR/var/nix/db/db.sqlite" ]; then
		"$USR/bin/nix-store" --init >/dev/null 2>&1 || true
	fi
}

if [ "${1:-}" = "--finalize" ]; then
	# --- failsafe step: PATH may be unset; use absolute /system binaries ---
	RM=/system/bin/rm
	MV=/system/bin/mv
	[ -x "$RM" ] || RM=rm
	[ -x "$MV" ] || MV=mv

	if [ -n "$APK_INSTALLER" ] && [ -x "$APK_INSTALLER" ]; then
		"$APK_INSTALLER" --finalize
	else
		[ -d "$USRN" ] || die "$USRN not found; run the preparation step first"
		$RM -rf "$USR.old"
		$MV "$USR" "$USR.old" || die "cannot move $USR aside"
		$MV "$USRN" "$USR" || { $MV "$USR.old" "$USR"; die "cannot move $USRN into place"; }
		# initialize apk db (the second-stage hook also does this on first boot)
		if [ -x "$USR/bin/apk" ]; then
			"$USR/bin/apk" add --initdb >/dev/null 2>&1 || true
		fi
	fi

	init_nix

	echo
	echo "Bootstrap swapped. Exit failsafe and start Termux normally, then:"
	echo "  apk update"
	echo "  nix --version && nix-env --version"
	echo "Old prefix kept at $USR.old; delete it once verified: rm -rf $USR.old"
	exit 0
fi

# --- preparation step ---
ZIP="${1:-}"
if [ -z "$ZIP" ]; then
	if [ -n "$BOOTSTRAP_URL_BASE" ]; then
		ZIP="$BOOTSTRAP_URL_BASE/nix-bootstrap-$ARCH.zip"
	else
		ZIP="./nix-bootstrap-$ARCH.zip"
	fi
fi

mkdir -p "$FILES"
if [ -f "$ZIP" ]; then
	cp "$ZIP" "$FILES/nix-bootstrap.zip"
else
	command -v curl >/dev/null || die "curl not found"
	echo "downloading $ZIP ..."
	curl -fL --progress-bar -o "$FILES/nix-bootstrap.zip" "$ZIP" || die "download failed"
fi

if [ -n "$APK_INSTALLER" ] && [ -x "$APK_INSTALLER" ]; then
	# Reuse the apk-tools installer for extraction, symlinks and checks.
	"$APK_INSTALLER" "$FILES/nix-bootstrap.zip"
	rm -f "$FILES/nix-bootstrap.zip"
else
	command -v unzip >/dev/null || die "unzip not found"

	[ -d "$USRN" ] && die "$USRN already exists; remove it or run --finalize first"
	mkdir -p "$USRN"
	echo "extracting bootstrap into $USRN ..."
	unzip -q "$FILES/nix-bootstrap.zip" -d "$USRN"

	[ -f "$USRN/SYMLINKS.txt" ] || die "SYMLINKS.txt missing from bootstrap"
	[ -x "$USRN/bin/apk" ] || die "bin/apk missing from bootstrap (is this an apk bootstrap?)"
	[ -x "$USRN/bin/nix" ] || die "bin/nix missing from bootstrap"

	echo "creating symlinks ..."
	while IFS='←' read -r target link; do
		[ -n "$target" ] || continue
		link="${link#./}"
		mkdir -p "$USRN/$(dirname "$link")"
		ln -sf "$target" "$USRN/$link"
	done < "$USRN/SYMLINKS.txt"
	rm -f "$USRN/SYMLINKS.txt" "$FILES/nix-bootstrap.zip"
fi

# The prefix must have the usual 755/644 permissions (tmp/ stays private).
if [ -d "$USRN" ]; then
	find "$USRN" -type d ! -path "$USRN/tmp" -exec chmod 755 {} + 2>/dev/null || true
	find "$USRN" -type f -perm -u+x -exec chmod 755 {} + 2>/dev/null || true
	find "$USRN" -type f ! -perm -u+x -exec chmod 644 {} + 2>/dev/null || true
fi

# Make sure this script is reachable from failsafe mode.
cp "$0" "$FILES/install-nix-bootstrap.sh" 2>/dev/null || true
chmod +x "$FILES/install-nix-bootstrap.sh" 2>/dev/null || true

echo
echo "Prepared. Now do the swap:"
echo "  1. Fully exit Termux and restart it in failsafe (recovery) mode:"
echo "     long-press Termux icon -> Failsafe"
echo "  2. in the failsafe session run:"
echo "     $FILES/install-nix-bootstrap.sh --finalize"
echo "  3. exit failsafe and start Termux normally"
echo
echo "After the swap: apk manages packages (apt/dpkg are gone), Nix manages"
echo "Nix store paths (nix, nix-env, nix-store)."
