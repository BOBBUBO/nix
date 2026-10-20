#!/bin/bash
# make-nix-bootstrap.sh [arch] [path-to-nix.deb]
#
# Takes a stock Termux bootstrap zip and injects Nix (built by this repo's
# CI or on-device) together with its runtime dependencies, producing a
# Termux bootstrap that has `nix`, `nix-env`, `nix-store`, ... available out
# of the box: nix-bootstrap-<arch>.zip
#
# Unlike the apk-tools bootstrap this keeps apt/dpkg: Nix cannot install
# Termux .deb packages (and stock nixpkgs does not bootstrap on Android), so
# removing apt would leave the user unable to install Termux packages. Nix is
# an additional, fully native package manager for Nix store paths; both can
# coexist. See packaging/termux/README.md.
#
# Requires: bash, curl, unzip, zip, tar, ar, xz/zstd/bzip2 (as needed by the
#           debs), and gh only when the nix deb is not given locally.
set -eu

TERMUX_PREFIX="/data/data/com.termux/files/usr"
ARCH="${1:-aarch64}"
NIX_DEB="${2:-}"
TERMUX_REPO="https://packages-cf.termux.dev/apt/termux-main"
WORKDIR="$(pwd)/.nix-bootstrap/$ARCH"
DEPS="libgc boost brotli bzip2 libarchive libcurl libgit2 liblz4 libseccomp libsodium libsqlite lowdown openssl readline zlib zstd xz-utils"
OUT="$(pwd)/nix-bootstrap-$ARCH.zip"
MOTD="$(pwd)/motd"

for cmd in curl unzip zip tar ar; do
	command -v "$cmd" >/dev/null || { echo "missing tool: $cmd"; exit 1; }
done

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/debs" "$WORKDIR/tree"
CACHEDIR="$(pwd)/.nix-bootstrap/cache"
mkdir -p "$CACHEDIR"

log() { echo "[*] $*"; }

# ---------------------------------------------------------------------------
# 1. stock bootstrap zip
# ---------------------------------------------------------------------------
STOCK_ZIP="$CACHEDIR/bootstrap-stock-$ARCH.zip"
if [ ! -f "$STOCK_ZIP" ]; then
	log "finding latest stock bootstrap release..."
	assets=$(curl -fsSL "https://api.github.com/repos/termux/termux-packages/releases?per_page=100")
	url=$(printf '%s\n' "$assets" \
		| grep -F '"browser_download_url"' \
		| grep -F "bootstrap-$ARCH.zip\"" \
		| grep -oE 'https://[^"]+' \
		| head -1)
	[ -n "$url" ] || { echo "no bootstrap-$ARCH.zip asset found in recent releases"; exit 1; }
	log "downloading stock bootstrap: $url"
	curl -fL --progress-bar -o "$STOCK_ZIP.tmp" "$url" \
		&& mv "$STOCK_ZIP.tmp" "$STOCK_ZIP" \
		|| { rm -f "$STOCK_ZIP.tmp"; exit 1; }
fi
log "extracting stock bootstrap..."
unzip -q "$STOCK_ZIP" -d "$WORKDIR/tree"

# Stock zips remove symlinks into SYMLINKS.txt; recreate them so the
# injection steps see a real tree (and so we can regenerate the list).
log "materializing stock symlinks..."
while IFS='←' read -r target link; do
	[ -n "$target" ] || continue
	link="${link#./}"
	mkdir -p "$WORKDIR/tree/$(dirname "$link")"
	ln -sf "$target" "$WORKDIR/tree/$link"
done < "$WORKDIR/tree/SYMLINKS.txt"

# ---------------------------------------------------------------------------
# 2. fetch + inject dependency debs (recursively) from the Termux repo
# ---------------------------------------------------------------------------
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
		tar -C "${TERMUX_PREFIX#/}" -cf - . | tar -C "$WORKDIR/tree" -xf -)
	rm -rf "$tmp"
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
# 3. nix deb (local, or latest CI artifact)
# ---------------------------------------------------------------------------
if [ -z "$NIX_DEB" ]; then
	shopt -s nullglob
	g=( "$WORKDIR"/debs/nix_*_"$ARCH".deb ./nix_*_"$ARCH".deb )
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
# 4. runtime layout + nix.conf
# ---------------------------------------------------------------------------
log "initializing nix store/state directories..."
# The bootstrap tree root is $PREFIX itself (no data/data/... prefix).
BOOT="$WORKDIR/tree"
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
# 5. first-login Nix initialisation
# ---------------------------------------------------------------------------
# Do NOT replace the stock second-stage script: it runs the postinst scripts
# of every package in the bootstrap. Since we extract Nix from its .deb instead
# of installing it with dpkg, its postinst is not run; initialise the database
# from a profile hook on first login instead.
log "installing Nix first-login hook..."
mkdir -p "$BOOT/etc/profile.d"
cat > "$BOOT/etc/profile.d/99-nix-init.sh" <<- EOF
# shellcheck shell=sh
# Injected by make-nix-bootstrap.sh. Initialise the single-user Nix database
# once, since the bootstrap extracts the nix .deb instead of running dpkg.
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
# 6. motd
# ---------------------------------------------------------------------------
if [ -f "$MOTD" ]; then
	log "installing custom motd"
	install -Dm644 "$MOTD" "$WORKDIR/tree/etc/motd"
fi

# ---------------------------------------------------------------------------
# 7. regenerate SYMLINKS.txt and rezip
# ---------------------------------------------------------------------------
log "regenerating SYMLINKS.txt..."
(cd "$WORKDIR/tree" && rm -f SYMLINKS.txt && \
	find . -type l -print0 | sort -z | \
	while IFS= read -r -d '' link; do \
		echo "$(readlink "$link")←$link" >> SYMLINKS.txt; \
		rm -f "$link"; \
	done)

log "creating $OUT..."
rm -f "$OUT"
(cd "$WORKDIR/tree" && zip -q -r9 "$OUT" ./)

log "done."
echo
echo "== validation =="
unzip -l "$OUT" | grep -E "SYMLINKS|bin/nix$|etc/nix/nix.conf" | head
unzip -p "$OUT" SYMLINKS.txt | grep -qE '←\./bin/nix-env$' \
	|| { echo "error: SYMLINKS.txt lacks bin/nix-env" >&2; exit 1; }
unzip -p "$OUT" SYMLINKS.txt | grep -qE '←\./bin/nix-store$' \
	|| { echo "error: SYMLINKS.txt lacks bin/nix-store" >&2; exit 1; }
conf=$(unzip -p "$OUT" etc/nix/nix.conf)
for key in sandbox substitute build-dir experimental-features; do
	printf '%s\n' "$conf" | grep -qE "^[[:space:]]*$key[[:space:]]*=" \
		|| { echo "error: nix.conf lacks $key" >&2; exit 1; }
done
if unzip -l "$OUT" | grep -qE "bin/(apt|dpkg)"; then
	echo "apt/dpkg retained: Termux packages keep working (Nix cannot install .debs)"
fi
echo
echo "Bootstrap ready: $OUT ($(du -h "$OUT" | cut -f1))"
echo "Flash it on a device with a Termux app build that loads a custom"
echo "bootstrap zip, or extract it as a secondary prefix for testing."
