#!/bin/bash
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Rebuild NumPy's extension modules for iOS arm64 and relink them as MH_DYLIB, so
# `prepare_testflight.py` can package them as frameworks (ROUND5 8F.1).
#
#     release/ios/build_numpy_ios.sh <work-dir> <output-dir>
#
# The prebuilt iOS libraries (`lib/ios_arm64`) ship NumPy's modules as MH_BUNDLE, which App Store
# packaging cannot turn into frameworks, and keep no Meson build directory to relink them from. This
# reproduces the Apple cross-build branch of `build_files/build_environment/cmake/numpy.cmake` (same
# version and hash from `versions.cmake`, same Meson options, the same cross and native files), then
# runs `relink_python_extensions.py` on the Meson build directory and checks the result with
# `check_numpy_replacements.py` against the bundled modules.
#
# <work-dir> holds the download, the source, the ini files and the Meson build; it is reused when
# run again. <output-dir> receives `numpy/**/*.so`, and must not exist yet. Nothing is written in
# the checkout. Needs network access the first time (the source release from GitHub), and `ninja`
# and `pkg-config` on PATH.
#
# Settings, all optional, from the environment:
#   HOST_PYTHON      Mac Python with Cython (default: lib/macos_arm64's python3.13)
#   TARGET_PYTHON    iOS Python: headers and sysconfig data (default: lib/ios_arm64/python)
#   MINIMUM_OS       deployment target of the modules (default: 26.0, the bundled libraries' floor)
#   JOBS             parallel compile jobs (default: the number of CPUs)
#
# **The extension suffix.** Meson asks the cross file's Python (the Mac's) for the extension
# suffix, and gets the Mac's `.cpython-313-darwin.so`. iOS Python looks for
# `.cpython-313-arm64-iphoneos.so`. So Meson runs with
# `_PYTHON_SYSCONFIGDATA_NAME=_sysconfigdata__darwin_arm64-iphoneos` and `PYTHONPATH` set to a
# directory holding only that one file, copied from the iOS Python; with the whole iOS standard
# library on the path instead, the Mac interpreter would import iOS modules and fail. Without it,
# the modules build, relink and package, with the wrong file names.

set -euo pipefail

if [ $# -ne 2 ]; then
  sed -n '7,9p' "$0" | sed 's/^# \{0,4\}//'
  exit 2
fi

BLENDER_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$1"
BUILD_DIR="$(cd "$1" && pwd)"
OUTPUT_DIR="$2"
HOST_PYTHON="${HOST_PYTHON:-$BLENDER_DIR/lib/macos_arm64/python/bin/python3.13}"
TARGET_PYTHON="${TARGET_PYTHON:-$BLENDER_DIR/lib/ios_arm64/python}"
PYTHON_SHORT_VERSION=3.13
MINIMUM_OS="${MINIMUM_OS:-26.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu)}"

# The host Python lives inside the checkout; keep it from writing `__pycache__` there.
export PYTHONDONTWRITEBYTECODE=1
RECIPE_DIR="$BLENDER_DIR/build_files/build_environment/cmake"
VERSIONS="$RECIPE_DIR/versions.cmake"
SYSCONFIG_NAME="_sysconfigdata__darwin_arm64-iphoneos"
SITE_PACKAGES="$TARGET_PYTHON/lib/python$PYTHON_SHORT_VERSION/site-packages"

for tool in ninja pkg-config; do
  command -v "$tool" >/dev/null || { echo "build_numpy_ios: $tool is not on PATH" >&2; exit 1; }
done
[ -x "$HOST_PYTHON" ] || { echo "build_numpy_ios: no host Python at $HOST_PYTHON" >&2; exit 1; }
if [ -e "$OUTPUT_DIR" ]; then
  echo "build_numpy_ios: the output exists, remove it first: $OUTPUT_DIR" >&2
  exit 1
fi

cmake_var() {
  sed -n "s/^set($1 \(.*\))$/\1/p" "$VERSIONS"
}
NUMPY_VERSION="$(cmake_var NUMPY_VERSION)"
NUMPY_HASH="$(cmake_var NUMPY_HASH)"
NUMPY_HASH_TYPE="$(cmake_var NUMPY_HASH_TYPE)"
NUMPY_URI="https://github.com/numpy/numpy/releases/download/v${NUMPY_VERSION}/numpy-${NUMPY_VERSION}.tar.gz"
BUNDLED_VERSION="$(sed -n 's/^version = "\(.*\)"$/\1/p' "$SITE_PACKAGES/numpy/version.py")"
if [ "$NUMPY_VERSION" != "$BUNDLED_VERSION" ]; then
  echo "build_numpy_ios: versions.cmake has NumPy $NUMPY_VERSION, the bundled one is $BUNDLED_VERSION" >&2
  exit 1
fi
if [ "$NUMPY_HASH_TYPE" != "MD5" ]; then
  echo "build_numpy_ios: unexpected hash type $NUMPY_HASH_TYPE" >&2
  exit 1
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SRC="$BUILD_DIR/src"
MESON_BUILD="$BUILD_DIR/build"
MESON=("$HOST_PYTHON" "$SRC/vendored-meson/meson/meson.py")

# 1. Download and verify.
mkdir -p "$BUILD_DIR/download"
ARCHIVE="$BUILD_DIR/download/numpy-$NUMPY_VERSION.tar.gz"
if [ ! -f "$ARCHIVE" ]; then
  curl -fsSL -o "$ARCHIVE.part" "$NUMPY_URI"
  mv "$ARCHIVE.part" "$ARCHIVE"
fi
ACTUAL="$(md5 -q "$ARCHIVE")"
if [ "$ACTUAL" != "$NUMPY_HASH" ]; then
  echo "build_numpy_ios: hash mismatch for $ARCHIVE: $ACTUAL, expected $NUMPY_HASH" >&2
  exit 1
fi
echo "Verified NumPy $NUMPY_VERSION ($NUMPY_HASH_TYPE $ACTUAL)"
if [ ! -d "$SRC" ]; then
  rm -rf "$BUILD_DIR/extract"
  mkdir -p "$BUILD_DIR/extract"
  tar -xzf "$ARCHIVE" -C "$BUILD_DIR/extract"
  mv "$BUILD_DIR/extract/numpy-$NUMPY_VERSION" "$SRC"
  rmdir "$BUILD_DIR/extract"
fi
# The recipe applies no patches to NumPy for the Apple cross build.

# 2. Configure and compile. The two templates, with the variables numpy.cmake gives
# configure_file() (the compilers are the ones the bundled `numpy/__config__.py` names).
fill() {
  sed -e "s|@CMAKE_C_COMPILER@|/usr/bin/cc|g" \
      -e "s|@CMAKE_CXX_COMPILER@|/usr/bin/c++|g" \
      -e "s|@CMAKE_AR@|/usr/bin/ar|g" \
      -e "s|@CMAKE_STRIP@|/usr/bin/strip|g" \
      -e "s|@PYTHON_BINARY@|$HOST_PYTHON|g" \
      -e "s|@CMAKE_OSX_SYSROOT@|$SDK|g" \
      -e "s|@APPLE_OS_MINVERSION_CFLAG@|-miphoneos-version-min=$MINIMUM_OS|g" \
      -e "s|@LIBDIR@/python|$TARGET_PYTHON|g" \
      -e "s|@PYTHON_SHORT_VERSION@|$PYTHON_SHORT_VERSION|g" \
      "$1" > "$2"
  if grep -q '@[A-Z_]*@' "$2"; then
    echo "build_numpy_ios: unfilled variable in $2" >&2
    exit 1
  fi
}
fill "$RECIPE_DIR/numpy_apple_cross.ini.in" "$BUILD_DIR/numpy-cross.ini"
fill "$RECIPE_DIR/numpy_apple_native.ini.in" "$BUILD_DIR/numpy-native.ini"

# The extension suffix: see the header.
rm -rf "$BUILD_DIR/target_sysconfig"
mkdir -p "$BUILD_DIR/target_sysconfig"
cp "$TARGET_PYTHON/lib/python$PYTHON_SHORT_VERSION/$SYSCONFIG_NAME.py" "$BUILD_DIR/target_sysconfig/"

if [ ! -f "$MESON_BUILD/build.ninja" ]; then
  env _PYTHON_SYSCONFIGDATA_NAME="$SYSCONFIG_NAME" \
      PYTHONPATH="$BUILD_DIR/target_sysconfig" \
      IPHONEOS_DEPLOYMENT_TARGET="$MINIMUM_OS" \
    "${MESON[@]}" setup "$MESON_BUILD" "$SRC" \
      --cross-file="$BUILD_DIR/numpy-cross.ini" \
      --native-file="$BUILD_DIR/numpy-native.ini" \
      --prefix="$BUILD_DIR/install" \
      --buildtype=release \
      -Dblas=none -Dlapack=none \
      -Dpython.platlibdir="lib/python$PYTHON_SHORT_VERSION/site-packages" \
      -Dpython.purelibdir="lib/python$PYTHON_SHORT_VERSION/site-packages"
fi
# With the same environment as the setup: a build folder used before regenerates itself here when
# its cross file is written again, and without it asks the Mac's Python for the suffix (ROUND7 IN).
env _PYTHON_SYSCONFIGDATA_NAME="$SYSCONFIG_NAME" \
    PYTHONPATH="$BUILD_DIR/target_sysconfig" \
    IPHONEOS_DEPLOYMENT_TARGET="$MINIMUM_OS" \
  "${MESON[@]}" compile -C "$MESON_BUILD" -j "$JOBS"

# 3. Relink every extension module as MH_DYLIB, then check it against the module it replaces.
"$HOST_PYTHON" "$BLENDER_DIR/release/ios/relink_python_extensions.py" \
  "$MESON_BUILD" "$OUTPUT_DIR" --minimum-os "$MINIMUM_OS"
"$HOST_PYTHON" "$BLENDER_DIR/release/ios/check_numpy_replacements.py" \
  "$SITE_PACKAGES/numpy" "$OUTPUT_DIR" --minimum-os "$MINIMUM_OS"
