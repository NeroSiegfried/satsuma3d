#!/bin/bash
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Rebuild OpenImageDenoise for iOS arm64 with its framework loader, so the denoiser works in the
# packaged (framework) layout of a tester build (ROUND5 8K).
#
#     release/ios/build_oidn_ios.sh <work-dir> <output-dir>
#
# OpenImageDenoise loads its device modules at run time, by path, from the folder its core library
# is in. In a tester build every library is a framework of its own, so the core must look in the
# sibling framework instead: `build_files/build_environment/patches/oidn_ios_frameworks.diff`
# teaches it that. The prebuilt `lib/ios_arm64/openimagedenoise` was built without that patch, and
# on the iPad said "no supported devices found" (2026-11-18). This reproduces the iOS branch of
# `build_files/build_environment/cmake/openimagedenoise.cmake`: the same version and hash from
# `versions.cmake`, `oidn.diff` and `oidn_ios_frameworks.diff`, the Metal device only
# (`OIDN_DEVICE_METAL=ON`, `OIDN_DEVICE_CPU=OFF`, no apps, no lightmap filter), Release. Then it puts
# the three libraries in <output-dir> under the prebuilt files' names and install names, and checks
# them against the prebuilt set with `check_oidn_replacements.py`.
#
# <work-dir> holds the download, the patched source, the build and its install; it is reused when
# run again (the source is extracted and patched afresh each time). <output-dir> receives the three
# `.dylib` files, and must not exist yet. Nothing is written in the checkout. Needs network access
# the first time (the source release from GitHub, about 90 MB), Xcode's iPhoneOS SDK and Metal
# toolchain, and Homebrew's `cmake` and `ninja`.
#
# Settings, all optional, from the environment:
#   HOST_PYTHON      Mac Python OpenImageDenoise's build uses to embed its weights
#                    (default: lib/macos_arm64's python3.13)
#   PREBUILT         the prebuilt libraries to match (default: lib/ios_arm64/openimagedenoise/lib)
#   JOBS             parallel compile jobs (default: the number of CPUs)
#
# **Run paths.** The libraries' build would leave the work directory in each library's LC_RPATH
# (the prebuilt ones carry their builder's `/opt/...` folder the same way). The app finds them
# through its own run paths, so the replacements carry none: a tester's build holds no path of
# this Mac.

set -euo pipefail

if [ $# -ne 2 ]; then
  sed -n '9,11p' "$0" | sed 's/^# \{0,4\}//'
  exit 2
fi

BLENDER_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$1"
WORK_DIR="$(cd "$1" && pwd)"
OUTPUT_DIR="$2"
HOST_PYTHON="${HOST_PYTHON:-$BLENDER_DIR/lib/macos_arm64/python/bin/python3.13}"
PREBUILT="${PREBUILT:-$BLENDER_DIR/lib/ios_arm64/openimagedenoise/lib}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# The host Python lives inside the checkout; keep it from writing `__pycache__` there.
export PYTHONDONTWRITEBYTECODE=1
RECIPES="$BLENDER_DIR/build_files/build_environment"
VERSIONS="$RECIPES/cmake/versions.cmake"
PATCHES=("$RECIPES/patches/oidn.diff" "$RECIPES/patches/oidn_ios_frameworks.diff")

for tool in cmake ninja xcrun; do
  command -v "$tool" >/dev/null || { echo "build_oidn_ios: $tool is not on PATH" >&2; exit 1; }
done
[ -x "$HOST_PYTHON" ] || { echo "build_oidn_ios: no host Python at $HOST_PYTHON" >&2; exit 1; }
[ -d "$PREBUILT" ] || { echo "build_oidn_ios: no prebuilt libraries at $PREBUILT" >&2; exit 1; }
xcrun --sdk iphoneos metal --version >/dev/null 2>&1 \
  || { echo "build_oidn_ios: Xcode's Metal toolchain is missing (xcodebuild -downloadComponent MetalToolchain)" >&2; exit 1; }
if [ -e "$OUTPUT_DIR" ]; then
  echo "build_oidn_ios: the output exists, remove it first: $OUTPUT_DIR" >&2
  exit 1
fi

cmake_var() {
  sed -n "s/^set($1 \(.*\))$/\1/p" "$VERSIONS"
}
OIDN_VERSION="$(cmake_var OIDN_VERSION)"
OIDN_HASH="$(cmake_var OIDN_HASH)"
OIDN_HASH_TYPE="$(cmake_var OIDN_HASH_TYPE)"
OIDN_URI="https://github.com/RenderKit/oidn/releases/download/v${OIDN_VERSION}/oidn-${OIDN_VERSION}.src.tar.gz"
if [ "$OIDN_HASH_TYPE" != "MD5" ]; then
  echo "build_oidn_ios: unexpected hash type $OIDN_HASH_TYPE" >&2
  exit 1
fi
# The prebuilt set names the version in its file names; a rebuild of another version replaces nothing.
if [ ! -f "$PREBUILT/libOpenImageDenoise_core.$OIDN_VERSION.dylib" ]; then
  echo "build_oidn_ios: versions.cmake has OpenImageDenoise $OIDN_VERSION, the prebuilt set is not that version" >&2
  exit 1
fi

SRC="$WORK_DIR/src"
BUILD="$WORK_DIR/build"
INSTALL="$WORK_DIR/install"

# 1. Download and verify.
mkdir -p "$WORK_DIR/download"
ARCHIVE="$WORK_DIR/download/oidn-$OIDN_VERSION.src.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
  curl -fsSL -o "$ARCHIVE.part" "$OIDN_URI"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL="$(md5 -q "$ARCHIVE")"
if [ "$ACTUAL" != "$OIDN_HASH" ]; then
  echo "build_oidn_ios: hash mismatch for $ARCHIVE: $ACTUAL, expected $OIDN_HASH" >&2
  exit 1
fi
echo "Verified OpenImageDenoise $OIDN_VERSION ($OIDN_HASH_TYPE $ACTUAL)"

# 2. Extract and patch, afresh: a patch applied twice, or half, is not the recipe's source.
rm -rf "$SRC" "$WORK_DIR/extract"
mkdir -p "$WORK_DIR/extract"
tar -xzf "$ARCHIVE" -C "$WORK_DIR/extract"
mv "$WORK_DIR/extract/oidn-$OIDN_VERSION" "$SRC"
rmdir "$WORK_DIR/extract"
for diff in "${PATCHES[@]}"; do
  patch -p1 -N -d "$SRC" < "$diff" > /dev/null \
    || { echo "build_oidn_ios: $(basename "$diff") does not apply" >&2; exit 1; }
  echo "Applied $(basename "$diff")"
done
grep -q '".framework/"' "$SRC/core/module.cpp" \
  || { echo "build_oidn_ios: the framework lookup is not in core/module.cpp after patching" >&2; exit 1; }

# 3. Configure, compile, install. OpenImageDenoise sets the iOS deployment target itself (14.0, as
# the prebuilt set has it) and compiles its Metal kernels for iOS 16. The source folder is mapped
# to a neutral name, so no path of this Mac is compiled into the libraries.
rm -rf "$BUILD" "$INSTALL"
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$INSTALL" \
  -DCMAKE_C_FLAGS="-ffile-prefix-map=$SRC=oidn-$OIDN_VERSION -ffile-prefix-map=$BUILD=oidn-build" \
  -DCMAKE_CXX_FLAGS="-ffile-prefix-map=$SRC=oidn-$OIDN_VERSION -ffile-prefix-map=$BUILD=oidn-build" \
  -DCMAKE_OBJCXX_FLAGS="-ffile-prefix-map=$SRC=oidn-$OIDN_VERSION -ffile-prefix-map=$BUILD=oidn-build" \
  -DOIDN_APPS=OFF \
  -DOIDN_FILTER_RTLIGHTMAP=OFF \
  -DOIDN_DEVICE_METAL=ON \
  -DOIDN_DEVICE_CPU=OFF \
  -DPython_EXECUTABLE="$HOST_PYTHON" \
  > "$WORK_DIR/configure.log" 2>&1 \
  || { tail -30 "$WORK_DIR/configure.log" >&2; echo "build_oidn_ios: configure failed ($WORK_DIR/configure.log)" >&2; exit 1; }
# The core asks for `OpenImageDenoise_<module>` + SHARED_POSTFIX (`oidn.diff`), which must be empty
# for the name `prepare_testflight.py` gives the module's framework.
grep -q 'SHARED_POSTFIX=\\"\\"' "$BUILD/build.ninja" \
  || { echo "build_oidn_ios: the core's module postfix is not empty in this build" >&2; exit 1; }
cmake --build "$BUILD" -j "$JOBS" > "$WORK_DIR/build.log" 2>&1 \
  || { grep -E 'error:|Error' "$WORK_DIR/build.log" | head -20 >&2; echo "build_oidn_ios: build failed ($WORK_DIR/build.log)" >&2; exit 1; }
cmake --install "$BUILD" > "$WORK_DIR/install.log" 2>&1 \
  || { tail -20 "$WORK_DIR/install.log" >&2; echo "build_oidn_ios: install failed" >&2; exit 1; }

# 4. The output: each real (not symbolic link) prebuilt library, replaced by the rebuilt file of the
# same name, with the prebuilt one's install name and no run paths.
mkdir -p "$OUTPUT_DIR"
for prebuilt in "$PREBUILT"/*.dylib; do
  [ -L "$prebuilt" ] && continue
  name="$(basename "$prebuilt")"
  rebuilt="$INSTALL/lib/$name"
  [ -f "$rebuilt" ] || { echo "build_oidn_ios: the build made no $name" >&2; exit 1; }
  cp "$rebuilt" "$OUTPUT_DIR/$name"
  chmod u+w "$OUTPUT_DIR/$name"
  identity="$(xcrun otool -D "$prebuilt" | sed -n 2p)"
  xcrun install_name_tool -id "$identity" "$OUTPUT_DIR/$name" 2>/dev/null
  xcrun otool -l "$OUTPUT_DIR/$name" | awk '/cmd LC_RPATH/ {getline; getline; print $2}' |
    while IFS= read -r path; do
      xcrun install_name_tool -delete_rpath "$path" "$OUTPUT_DIR/$name" 2>/dev/null
    done
  # install_name_tool invalidates the build's ad hoc signature; sign again (packaging signs again).
  xcrun codesign --force --sign - "$OUTPUT_DIR/$name" 2>/dev/null
done

# 5. Check against the prebuilt set.
"$HOST_PYTHON" "$BLENDER_DIR/release/ios/check_oidn_replacements.py" "$PREBUILT" "$OUTPUT_DIR"
