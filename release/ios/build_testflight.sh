#!/bin/bash
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# One command from nothing to a tester build of the iPad app (ROUND5 8F.4).
#
#     release/ios/build_testflight.sh [<settings-file>]
#
# Steps, each logged to <build-dir>/logs/:
#   1. configure  a separate Xcode build directory for the tester app (never the development one)
#   2. build      the `install` target, unsigned
#   3. stage      `cmake --install`: the complete app at <build-dir>/bin/Blender.app
#   4. numpy      NumPy's modules rebuilt and relinked as dynamic libraries (`build_numpy_ios.sh`)
#   5. oidn       OpenImageDenoise rebuilt to find its device module as a framework (`build_oidn_ios.sh`)
#   6. prepare    every library a framework, without app extensions (`prepare_testflight.py`)
#   7. checks     identity, layout, privacy manifests, artwork (`test_testflight_packaging.py`)
#   8. archive    signed `.xcarchive` (`archive_testflight.py`), and
#   9. export     an App Store `.ipa` on disk (`xcodebuild -exportArchive`, destination `export`)
# Steps 8 and 9 run only when the settings name a team and a signing identity, a provisioning
# profile for <team>.<bundle id> is installed, and the checkout is clean; otherwise the script
# stops after the checks and says what is missing. **It never uploads**: there is no upload step,
# and the export options say `destination` `export`. Uploading is the owner's, each time (G4).
#
# The settings file (default: `testflight.env` beside the checkout) is outside the repository
# because it holds the team; see `testflight.env.example` for its keys. Every key is optional
# except as stated there. The development build (`build_ios_device`, `app.platypus3d.dev`) is not
# touched. The thumbnail extension is not built (`IOS_THUMBNAIL_EXTENSION=OFF`, decision 36: it
# needs an App ID and profile of its own), and preparing leaves out any app extension.
#
# Needs Xcode with the iPhoneOS SDK and its Metal toolchain, Homebrew's cmake, ninja and
# pkg-config, the libraries in `lib/ios_arm64` and `lib/macos_arm64`, and network access the first
# time (NumPy's and OpenImageDenoise's source releases).

set -euo pipefail

main() {
  local checkout workspace settings
  checkout="$(cd "$(dirname "$0")/../.." && pwd)"
  workspace="$(dirname "$checkout")"
  settings="${1:-$workspace/testflight.env}"

  # Defaults; the settings file overrides them.
  BUNDLE_ID=app.satsuma3d
  PRODUCT_NAME="Satsuma 3D"
  MARKETING_VERSION=0.1.0
  BUILD_NUMBER=1
  SOURCE_URL=https://github.com/NeroSiegfried/satsuma3d
  MINIMUM_OS=27.0
  TEAM_ID=
  SIGNING_IDENTITY=
  PROFILE=
  BUILD_DIR="$workspace/build_ios_testflight"
  LIBDIR="$checkout/lib/ios_arm64"
  if [ -f "$settings" ]; then
    echo "Settings: $settings"
    set -a
    # shellcheck disable=SC1090
    . "$settings"
    set +a
  else
    echo "Settings: none at $settings, using the defaults (no team: stops after the checks)"
  fi
  case "$BUNDLE_ID" in
    *.dev) fail "BUNDLE_ID $BUNDLE_ID ends in .dev: that is the development app's; a tester build needs its own" ;;
  esac
  [ -n "$SOURCE_URL" ] || fail "SOURCE_URL is empty: a build for other people must name its source"

  local release="$checkout/release/ios"
  local logs="$BUILD_DIR/logs"
  local python=python3
  if [ -x /opt/homebrew/bin/brew ]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  fi
  export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
  for tool in cmake ninja pkg-config xcodebuild; do
    command -v "$tool" >/dev/null || fail "$tool is not on PATH"
  done
  [ -d "$LIBDIR" ] || fail "no iOS libraries at $LIBDIR"
  if [ "$BUILD_DIR" = "$workspace/build_ios_device" ]; then
    fail "BUILD_DIR is the development build; tester builds use their own (decision 37)"
  fi
  mkdir -p "$logs"

  # The commit the build names as its source.
  local commit dirty=""
  commit="$(git -C "$checkout" rev-parse HEAD)"
  if [ -n "$(git -C "$checkout" status --porcelain --untracked-files=no)" ]; then
    dirty=yes
    echo "NOTE: the checkout has uncommitted changes, so this build is not exactly the source at"
    echo "      $commit. It is built and checked, but not archived."
  fi

  # Room for a second full build: about the size of an existing one, and the same again to spare.
  local free_gb need_gb=20
  free_gb=$(df -g "$workspace" | awk 'NR==2 {print $4}')
  if [ -d "$workspace/build_ios_device" ]; then
    need_gb=$(( $(du -sg "$workspace/build_ios_device" | awk '{print $1}') * 2 + 10 ))
  fi
  [ "$free_gb" -ge "$need_gb" ] || fail "$free_gb GB free, this build wants $need_gb GB"
  echo "Disk: $free_gb GB free, $need_gb GB wanted"

  # Without a team the build is unsigned; the install step still signs the bundled libraries,
  # ad hoc ("-"). Packaging strips nothing it needs: the archive signs everything again.
  export EXPANDED_CODE_SIGN_IDENTITY="${SIGNING_IDENTITY:--}"

  # 1. Configure.
  step configure
  local team_args=()
  [ -n "$TEAM_ID" ] && team_args=(-DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM="$TEAM_ID")
  cmake -S "$checkout" -B "$BUILD_DIR" -G Xcode \
    -DWITH_APPLE_CROSSPLATFORM=ON -DAPPLE_TARGET_DEVICE=ios \
    -DIOS_MIN_DEPLOYMENT_TARGET="$MINIMUM_OS" \
    -DLIBDIR="$LIBDIR" \
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_STYLE=Automatic \
    -DCMAKE_XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
    "${team_args[@]+"${team_args[@]}"}" \
    -DIOS_PRODUCT_NAME="$PRODUCT_NAME" \
    -DIOS_MARKETING_VERSION="$MARKETING_VERSION" \
    -DIOS_BUNDLE_VERSION="$BUILD_NUMBER" \
    -DIOS_SOURCE_URL="$SOURCE_URL" \
    -DWITH_INSTALL_COPYRIGHT=ON -DWITH_OPENAL=OFF \
    -DIOS_THUMBNAIL_EXTENSION=OFF \
    > "$logs/configure.log" 2>&1 || fail_log configure

  # 2. Build. Without the thumbnail extension nothing is embedded, so an unsigned build has no
  # expected failure: any failure is one. (With it, the unsigned extension fails Xcode's
  # `ValidateEmbeddedBinary`, and Xcode cancels the app's post-build steps, which compile its
  # icon: the app is then built without one.)
  step build
  if ! xcodebuild -project "$BUILD_DIR/Blender.xcodeproj" -target install -configuration Release \
       -parallelizeTargets CODE_SIGNING_ALLOWED=NO > "$logs/build.log" 2>&1; then
    grep " error:" "$logs/build.log" | sort -u | head -20
    fail_log build
  fi
  local product="$BUILD_DIR/bin/Release/Blender.app"
  [ -f "$product/Blender" ] || fail_log build

  # 3. Stage. The install copies Xcode's product over the freshly installed scripts, and that
  # product's copy is from whenever Xcode last ran the install: drop it, the scripts rule
  # provides them (as `deploy_ipad.sh` does).
  step stage
  rm -rf "$product"/Assets/*/scripts
  cmake --install "$BUILD_DIR" --config Release > "$logs/stage.log" 2>&1 || fail_log stage
  local app="$BUILD_DIR/bin/Blender.app"
  local scripts
  scripts="$(ls -d "$app"/Assets/*/scripts | head -1)"
  cmp -s "$checkout/scripts/startup/bl_ui/native_actions.py" "$scripts/startup/bl_ui/native_actions.py" \
    || fail "the staged scripts differ from the checkout's"
  [ -f "$(dirname "$scripts")/extensions/system/looptools/__init__.py" ] || fail "LoopTools is not bundled"

  # 4. NumPy. Reused when an earlier run made it and it still passes the check.
  step numpy
  local replacements="$BUILD_DIR/numpy_replacements"
  local bundled_numpy="$LIBDIR/python/lib/python3.13/site-packages/numpy"
  if [ -d "$replacements" ] && "$python" -B "$release/check_numpy_replacements.py" \
       "$bundled_numpy" "$replacements" > "$logs/numpy-check.log" 2>&1; then
    echo "  reusing $replacements"
  else
    rm -rf "$replacements"
    "$release/build_numpy_ios.sh" "$BUILD_DIR/numpy" "$replacements" > "$logs/numpy.log" 2>&1 \
      || fail_log numpy
    tail -1 "$logs/numpy.log"
  fi

  # 5. OpenImageDenoise, with its framework loader (ROUND5 8K). Reused like NumPy's.
  step oidn
  local denoiser="$BUILD_DIR/oidn_replacements"
  local bundled_oidn="$LIBDIR/openimagedenoise/lib"
  if [ -d "$denoiser" ] && (cd "$release" && "$python" -B check_oidn_replacements.py \
       "$bundled_oidn" "$denoiser") > "$logs/oidn-check.log" 2>&1; then
    echo "  reusing $denoiser"
  else
    rm -rf "$denoiser"
    PREBUILT="$bundled_oidn" "$release/build_oidn_ios.sh" "$BUILD_DIR/oidn" "$denoiser" \
      > "$logs/oidn.log" 2>&1 || fail_log oidn
    tail -1 "$logs/oidn.log"
  fi

  # 6. Prepare.
  step prepare
  local prepared="$BUILD_DIR/prepared/Blender.app"
  rm -rf "$prepared"
  (cd "$release" && "$python" -B prepare_testflight.py "$app" "$prepared" \
     --replacement-directory "$replacements" --replacement-directory "$denoiser" \
     --without-plugins) > "$logs/prepare.log" 2>&1 \
    || fail_log prepare
  tail -1 "$logs/prepare.log"

  # 7. Checks.
  step checks
  "$python" -B - "$prepared" "$BUNDLE_ID" "$PRODUCT_NAME" "$MARKETING_VERSION" "$BUILD_NUMBER" \
    "$SOURCE_URL" "$MINIMUM_OS" "$commit" <<'PYTHON' || fail "the prepared app's identity is wrong"
import plistlib, sys
from pathlib import Path
app, bundle_id, name, version, build, source, minimum, commit = sys.argv[1:]
info = plistlib.loads((Path(app) / 'Info.plist').read_bytes())
expected = {
    'CFBundleIdentifier': bundle_id, 'CFBundleName': name, 'CFBundleDisplayName': name,
    'CFBundleShortVersionString': version, 'CFBundleVersion': build,
    'SatsumaSourceURL': source, 'SatsumaSourceCommit': commit,
    'MinimumOSVersion': minimum, 'UIDeviceFamily': [2],
    'CFBundleSupportedPlatforms': ['iPhoneOS'], 'ITSAppUsesNonExemptEncryption': False,
}
wrong = [f'{key} is {info.get(key)!r}, expected {value!r}' for key, value in expected.items()
         if info.get(key) != value]
if (Path(app) / 'PlugIns').exists():
    wrong.append('the app carries PlugIns (decision 36)')
for line in wrong:
    print('  ' + line)
print(f'  identity: {bundle_id} {version} ({build}), source {source} at {commit[:11]}')
sys.exit(1 if wrong else 0)
PYTHON
  (cd "$release" && "$python" -B -c 'import sys; from prepare_testflight import check_icons
problems = check_icons(sys.argv[1]); [print("  " + p) for p in problems]; sys.exit(1 if problems else 0)' \
     "$prepared") || fail "the prepared app's asset catalog is incomplete"
  echo "  icon and interface glyphs compiled"
  "$python" -B "$release/required_reason_apis.py" "$prepared" > "$logs/privacy.log" 2>&1 \
    || fail_log privacy
  echo "  privacy manifests: every required reason API declared"
  "$python" -B -m unittest "$checkout/tests/ios/test_testflight_packaging.py" > "$logs/tests.log" 2>&1 \
    || fail_log tests
  echo "  $(grep '^Ran ' "$logs/tests.log"), $(grep -E '^(OK|FAILED)' "$logs/tests.log")"
  echo "  $(ls -d "$prepared"/Frameworks/*.framework | wc -l | tr -d ' ') frameworks," \
    "$(du -sm "$prepared" | awk '{print $1}') MB"

  # 8–9. Archive and export, only with everything a signed build needs.
  local missing=()
  [ -n "$TEAM_ID" ] || missing+=("TEAM_ID (the paid team, gate G1)")
  [ -n "$SIGNING_IDENTITY" ] || missing+=("SIGNING_IDENTITY (a signing certificate of that team)")
  [ -z "$dirty" ] || missing+=("a clean checkout (commit or drop the changes)")
  if [ -n "$TEAM_ID" ]; then
    PROFILE="$("$python" -B - "$TEAM_ID" "$BUNDLE_ID" "$release/entitlements.plist" "$PROFILE" <<'PYTHON'
import datetime, plistlib, subprocess, sys
from pathlib import Path
team, bundle_id, entitlements, given = sys.argv[1:]
wanted = plistlib.loads(Path(entitlements).read_bytes())
home = Path.home()
candidates = [Path(given)] if given else sorted(
    [*(home / 'Library/Developer/Xcode/UserData/Provisioning Profiles').glob('*.mobileprovision'),
     *(home / 'Library/MobileDevice/Provisioning Profiles').glob('*.mobileprovision')],
    key=lambda path: path.stat().st_mtime, reverse=True)
for path in candidates:
    try:
        profile = plistlib.loads(subprocess.check_output(['security', 'cms', '-D', '-i', str(path)],
                                                         stderr=subprocess.DEVNULL))
    except (subprocess.CalledProcessError, OSError):
        continue
    granted = profile.get('Entitlements', {})
    if (team in profile.get('TeamIdentifier', [])
            and granted.get('application-identifier') == f'{team}.{bundle_id}'
            and profile['ExpirationDate'] > datetime.datetime.now()
            and all(key in granted for key in wanted)):
        print(path)
        break
PYTHON
)"
    [ -n "$PROFILE" ] || missing+=("a provisioning profile for $TEAM_ID.$BUNDLE_ID granting the app's entitlements")
  fi
  if [ ${#missing[@]} -gt 0 ]; then
    echo
    echo "Prepared and checked, unsigned: $prepared"
    echo "Not archived or exported. Missing:"
    printf '  - %s\n' "${missing[@]}"
    return 0
  fi

  step archive
  local archive="$BUILD_DIR/Satsuma3D.xcarchive"
  rm -rf "$archive"
  local dsym=()
  [ -d "$BUILD_DIR/bin/Release/Blender.app.dSYM" ] && dsym=(--dsym "$BUILD_DIR/bin/Release/Blender.app.dSYM")
  (cd "$release" && "$python" -B archive_testflight.py "$prepared" "$archive" --profile "$PROFILE" \
     --identity "$SIGNING_IDENTITY" "${dsym[@]+"${dsym[@]}"}") > "$logs/archive.log" 2>&1 \
    || fail_log archive

  step export
  local export_dir="$BUILD_DIR/export"
  rm -rf "$export_dir"
  # `destination` `export`: the package is written to disk. Nothing here sends it anywhere.
  cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>export</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><false/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" -allowProvisioningUpdates \
    > "$logs/export.log" 2>&1 || fail_log export
  echo
  echo "Archive: $archive"
  echo "Package: $(ls "$export_dir"/*.ipa)"
  echo "Nothing was uploaded. Validating and uploading are separate steps, on the owner's word."
}

step() {
  echo "== $1 ($(date '+%H:%M:%S'))"
}

fail() {
  echo "build_testflight: $*" >&2
  exit 1
}

fail_log() {
  local log="$BUILD_DIR/logs/$1.log"
  echo "build_testflight: step $1 failed; the end of $log:" >&2
  tail -20 "$log" >&2
  exit 1
}

# Everything runs from inside main(), which bash reads whole before running: editing this file
# while a build runs cannot change the running one.
main "$@"
exit $?
