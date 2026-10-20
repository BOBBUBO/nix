# Nix for Termux - native build of the patched source tree.
#
# This recipe is an overlay for termux/termux-packages. It is NOT part of the
# upstream termux-packages repository; the CI workflow copies it (and the
# patched Nix source tree) into packages/nix/ of a termux-packages checkout
# before building.
#
# The source tree (with the Android patches already applied) must be present
# at $TERMUX_PKG_BUILDER_DIR/src, which the workflow provides. See
# packaging/termux/README.md for the patch list and build rationale.

TERMUX_PKG_HOMEPAGE=https://nixos.org/
TERMUX_PKG_DESCRIPTION="Nix, the purely functional package manager (native Termux build)"
TERMUX_PKG_LICENSE="LGPL-2.1-or-later"
TERMUX_PKG_MAINTAINER="@termux-nix-native"
TERMUX_PKG_VERSION=2.36.0
TERMUX_PKG_REVISION=1

# Source is provided locally by the CI workflow, not downloaded.
TERMUX_PKG_SRCURL=
TERMUX_PKG_SKIP_SRC_EXTRACT=true
TERMUX_PKG_AUTO_UPDATE=false

# Runtime dependencies. boost is required at runtime: Nix links
# boost_context, boost_coroutine, boost_iostreams and boost_url.
# NOTE: the Boehm GC is packaged as "libgc" in Termux (it ships bdw-gc.pc,
# which is the name Nix's meson build looks for).
TERMUX_PKG_DEPENDS="libgc, boost, brotli, bzip2, libarchive, libcurl, libgit2, liblz4, libseccomp, libsodium, libsqlite, lowdown, openssl, readline, zlib, zstd, xz-utils"
TERMUX_PKG_BUILD_DEPENDS="boost-headers, nlohmann-json, toml11"

# nix.conf is generated in termux_step_post_make_install and preserved across
# package upgrades by dpkg.
TERMUX_PKG_CONFFILES="etc/nix/nix.conf"

TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-Dunit-tests=false
-Dfunctional-tests=false
-Ddoc-gen=false
-Djson-schema-checks=false
-Dnix-store:seccomp-sandboxing=auto
-Dlibcmd:readline-flavor=readline
-Dlibstore:store-dir=$TERMUX_PREFIX/nix/store
-Dlibstore:log-dir=$TERMUX_PREFIX/var/log/nix
--localstatedir=$TERMUX_PREFIX/var
--sysconfdir=$TERMUX_PREFIX/etc
"

termux_step_pre_configure() {
	# cmake is not installed system-wide in the build container; termux_setup_cmake
	# downloads it and prepends it to PATH (also used by meson's Boost detection).
	termux_setup_cmake

	# 1. Copy the patched source into place (provided by the CI workflow).
	cp -a "$TERMUX_PKG_BUILDER_DIR/src/." "$TERMUX_PKG_SRCDIR/"

	# 2. libblake3 is not packaged for Termux. Build a static copy so the
	#    resulting nix binaries are self-contained (no extra runtime dep).
	#    -fPIC is required because Nix links the archive into libnixutil.so.
	if [ ! -f "$TERMUX_PREFIX/lib/pkgconfig/libblake3.pc" ]; then
		rm -rf "$TERMUX_PKG_TMPDIR/blake3"
		git clone --depth 1 https://github.com/BLAKE3-team/BLAKE3 \
			"$TERMUX_PKG_TMPDIR/blake3" || termux_error_exit "Failed to clone BLAKE3"
		# NOTE: do NOT set CMAKE_SYSTEM_NAME=Android here. CMake's Android
		# standalone-toolchain mode fails its compiler check against the
		# Termux toolchain (ld.lld: cannot open crtbegin_dynamic.o). Use
		# Linux instead: it keeps the cross-compile machinery but relies on
		# the renamed NDK clang wrapper carrying the target. Without
		# CMAKE_SYSTEM_NAME, CMake overwrites -DCMAKE_SYSTEM_PROCESSOR with
		# the host processor, which makes BLAKE3 pick the x86-64 assembly.
		cmake -S "$TERMUX_PKG_TMPDIR/blake3/c" \
			-B "$TERMUX_PKG_TMPDIR/blake3/c/build" \
			-DCMAKE_BUILD_TYPE=Release \
			-DBUILD_SHARED_LIBS=OFF \
			-DCMAKE_POSITION_INDEPENDENT_CODE=ON \
			-DCMAKE_INSTALL_PREFIX="$TERMUX_PREFIX" \
			-DCMAKE_C_COMPILER="$CC" \
			-DCMAKE_CXX_COMPILER="$CXX" \
			-DCMAKE_SYSTEM_NAME=Linux \
			-DCMAKE_SYSTEM_PROCESSOR="$TERMUX_ARCH" \
			|| termux_error_exit "BLAKE3 cmake configure failed"
		cmake --build "$TERMUX_PKG_TMPDIR/blake3/c/build" -j"$(nproc)" \
			|| termux_error_exit "BLAKE3 build failed"
		cmake --install "$TERMUX_PKG_TMPDIR/blake3/c/build" \
			|| termux_error_exit "BLAKE3 install failed"

		# Ensure pkg-config metadata exists under the name Nix looks up
		# (dependency('libblake3')). CMake normally installs this file itself;
		# recreate it with the static-only flags if it is missing.
		if [ ! -f "$TERMUX_PREFIX/lib/pkgconfig/libblake3.pc" ]; then
			cat > "$TERMUX_PREFIX/lib/pkgconfig/libblake3.pc" <<-EOF
				prefix=$TERMUX_PREFIX
				exec_prefix=\${prefix}
				libdir=\${prefix}/lib
				includedir=\${prefix}/include

				Name: libblake3
				Description: BLAKE3 hash function (static, built for Nix)
				Version: 1.8.7
				Libs: -L\${libdir} -lblake3
				Cflags: -I\${includedir}
			EOF
		fi
	fi

	# 3. Termux's libgc package omits the C++ interface headers Nix's
	#    libexpr needs; fetch them from upstream bdwgc.
	mkdir -p "$TERMUX_PREFIX/include/gc"
	for h in gc_cpp.h gc_allocator.h; do
		if [ ! -f "$TERMUX_PREFIX/include/gc/$h" ]; then
			curl -fsSL --max-time 60 \
				"https://raw.githubusercontent.com/ivmai/bdwgc/v8.2.12/include/$h" \
				-o "$TERMUX_PREFIX/include/gc/$h" \
				|| termux_error_exit "Failed to fetch libgc header $h"
		fi
	done

	# 4. Help meson's Boost detection find Termux's prefix.
	export BOOST_INCLUDEDIR="$TERMUX_PREFIX/include"
	export BOOST_LIBRARYDIR="$TERMUX_PREFIX/lib"
}

# Meson's cmake-method dependency lookups (Nix needs toml11 this way) require a
# [cmake] section in the cross file. Without it meson maps the cross file's
# system='android' to CMAKE_SYSTEM_NAME=Android, which makes CMake's Android
# module hard-fail (no NDK variables set) and the dependency lookup dies with
# "Unable to obtain CMake system information". Override the stock step (as in
# scripts/build/configure/termux_step_configure_meson.sh, current master) and
# append the section: Linux keeps cmake in cross mode without NDK requirements,
# and CMAKE_PREFIX_PATH lets find_package() find the extracted dependency
# configs under $TERMUX_PREFIX/lib/cmake/.
termux_step_configure_meson() {
	termux_setup_meson

	local cmake_proc="$TERMUX_ARCH"
	[ "$cmake_proc" = "arm" ] && cmake_proc='armv7-a'
	cat >> "$TERMUX_MESON_CROSSFILE" <<-EOF

	[cmake]
	CMAKE_SYSTEM_NAME = 'Linux'
	CMAKE_SYSTEM_PROCESSOR = '$cmake_proc'
	CMAKE_PREFIX_PATH = '$TERMUX_PREFIX'
	EOF

	local _meson_buildtype="release"
	local _meson_stripflag="--strip"
	if [ "$TERMUX_DEBUG_BUILD" = "true" ]; then
		_meson_buildtype="debug"
		_meson_stripflag=
	fi

	CC=gcc CXX=g++ CFLAGS= CXXFLAGS= CPPFLAGS= LDFLAGS= $TERMUX_MESON \
		setup \
		$TERMUX_PKG_SRCDIR \
		$TERMUX_PKG_BUILDDIR \
		--$(test "${TERMUX_PKG_MESON_NATIVE}" = "true" && echo "native-file" || echo "cross-file") $TERMUX_MESON_CROSSFILE \
		--prefix $TERMUX_PREFIX \
		--libdir $TERMUX__PREFIX__LIB_SUBDIR \
		--includedir $TERMUX__PREFIX__INCLUDE_SUBDIR \
		--buildtype ${_meson_buildtype} \
		${_meson_stripflag} \
		$TERMUX_PKG_EXTRA_CONFIGURE_ARGS \
		|| (termux_step_configure_meson_failure_hook && false)
}

termux_step_post_make_install() {
	mkdir -p "$TERMUX_PREFIX/etc/nix"
	cat > "$TERMUX_PREFIX/etc/nix/nix.conf" <<-EOF
		# Native Termux build of Nix.
		# Sandboxing cannot work on Android (no user namespaces / no chroot
		# without root), so builds run in no-sandbox fallback mode.
		sandbox = false
		# cache.nixos.org serves paths under /nix/store, which cannot match
		# this store's $TERMUX_PREFIX/nix/store prefix. Disable pointless
		# cache queries; re-enable if the store is relocated to /nix/store.
		substitute = false
		# Keep build scratch space and logs under \$PREFIX: /tmp does not exist
		# on Android, and external storage cannot hold the store.
		build-dir = $TERMUX_PREFIX/var/nix/builds
		log-dir = $TERMUX_PREFIX/var/log/nix
		# cache.nixos.org serves paths under /nix/store, so substitution is
		# disabled unless the store is relocated to /nix/store (needs root).
		experimental-features = nix-command flakes
	EOF

	mkdir -p "$TERMUX_PREFIX/nix/store" \
		"$TERMUX_PREFIX/var/nix/builds" \
		"$TERMUX_PREFIX/var/nix/profiles" \
		"$TERMUX_PREFIX/var/log/nix"
}

termux_step_create_debscripts() {
	cat > ./postinst <<-EOF
		#!$TERMUX_PREFIX/bin/sh
		# Create the single-user store/state directories and initialise the
		# Nix database. Safe to run repeatedly (dpkg upgrade).
		mkdir -p "$TERMUX_PREFIX/nix/store" \\
			"$TERMUX_PREFIX/var/nix/builds" \\
			"$TERMUX_PREFIX/var/nix/profiles" \\
			"$TERMUX_PREFIX/var/log/nix"
		[ -e "$TERMUX_PREFIX/var/nix/db/db.sqlite" ] || \\
			"$TERMUX_PREFIX/bin/nix-store" --init >/dev/null 2>&1 || true
		exit 0
	EOF
	chmod 755 ./postinst
}
