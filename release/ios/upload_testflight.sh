#!/bin/bash
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Send one tester build to App Store Connect, on the owner's word (ROUND5 8L, L4; gate G4).
#
#     release/ios/upload_testflight.sh [<settings-file>]                       # prints, sends nothing
#     release/ios/upload_testflight.sh --upload-build <n> [<settings-file>]    # uploads build <n>
#
# Takes the archive `build_testflight.sh` made (`<build dir>/Satsuma3D.xcarchive`, with its exported
# `.ipa` beside it, so the export has run) and prints what it would send: the app, its version,
# build number, source commit, the encryption key and the verdict of `check_no_encryption_library.py`
# on the archived app. Then it checks:
#
# - the archive's bundle id, version and build number are the settings' (`testflight.env`);
# - the key and the verdict agree (ROUND5 8M, E4): `ITSAppUsesNonExemptEncryption` false with no
#   encryption library, no key with one; anything else, or a program the check cannot read, refuses;
# - the commit the app names (`SatsumaSourceCommit`) is in this checkout and is on the `github`
#   remote's `ipad/main` (read with `git ls-remote`; nothing is fetched): every tester's build has
#   its exact source published (the GPL; PLAN §3, decision 89);
# - the tag `testers/<version>-<n>` does not already name another commit.
#
# Without `--upload-build`, or with a number that is not the archive's build number, it stops
# there and sends nothing. With the right number it uploads with `xcodebuild -exportArchive` and
# export options `method` `app-store-connect`, `destination` `upload` (Xcode 27.2's
# `xcodebuild -help`; it signs in with the account in Xcode's settings), then tags the commit
# `testers/<version>-<n>` and pushes that tag, and only that tag, to `github`. Raise BUILD_NUMBER in
# the settings before the next build: App Store Connect refuses a number twice.
#
# **No agent runs this with `--upload-build` unless its brief quotes the owner's word, given in
# that session, for that build** (G4). Apple's processing and beta review follow the upload; read
# what App Store Connect reports afterwards.

set -euo pipefail

fail() {
  echo "upload_testflight: $*" >&2
  exit 1
}

main() {
  local upload_build="" settings=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --upload-build)
        [ $# -ge 2 ] || fail "--upload-build needs the build number"
        upload_build="$2"
        shift 2
        ;;
      -h|--help)
        sed -n '8,9p' "$0" | sed 's/^# \{0,4\}//'
        return 0
        ;;
      -*) fail "unknown option $1" ;;
      *) settings="$1"; shift ;;
    esac
  done

  local checkout workspace
  checkout="$(cd "$(dirname "$0")/../.." && pwd)"
  workspace="$(dirname "$checkout")"
  settings="${settings:-$workspace/testflight.env}"

  BUNDLE_ID=app.satsuma3d
  MARKETING_VERSION=0.1.0
  BUILD_NUMBER=1
  TEAM_ID=
  BUILD_DIR="$workspace/build_ios_testflight"
  REMOTE=github
  BRANCH=ipad/main
  if [ -f "$settings" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$settings"
    set +a
  else
    fail "no settings at $settings"
  fi

  local archive="$BUILD_DIR/Satsuma3D.xcarchive"
  local app="$archive/Products/Applications/Blender.app"
  [ -f "$app/Info.plist" ] || fail "no archive at $archive: run build_testflight.sh with a team first"
  local ipa
  ipa="$(ls "$BUILD_DIR"/export/*.ipa 2>/dev/null | head -1 || true)"
  [ -n "$ipa" ] || fail "no exported .ipa in $BUILD_DIR/export: the archive was never exported"

  read_key() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$app/Info.plist" 2>/dev/null || echo "(absent)"
  }
  local bundle_id version build commit name encryption
  bundle_id="$(read_key CFBundleIdentifier)"
  version="$(read_key CFBundleShortVersionString)"
  build="$(read_key CFBundleVersion)"
  commit="$(read_key SatsumaSourceCommit)"
  name="$(read_key CFBundleDisplayName)"
  encryption="$(read_key ITSAppUsesNonExemptEncryption)"

  echo "Would send to App Store Connect:"
  echo "  app        $name ($bundle_id)"
  echo "  version    $version"
  echo "  build      $build"
  echo "  commit     $commit"
  echo "  archive    $archive"
  echo "  package    $ipa"
  echo "  ITSAppUsesNonExemptEncryption  $encryption"
  local check_status=0 verdict
  verdict="$(python3 -B "$checkout/release/ios/check_no_encryption_library.py" "$app" 2>&1)" || check_status=$?
  verdict="$(echo "$verdict" | tail -1 | sed "s|: $app\$||")"
  echo "  encryption check  $verdict"

  local problems=()
  [ "$bundle_id" = "$BUNDLE_ID" ] || problems+=("the archive's bundle id is $bundle_id, the settings say $BUNDLE_ID")
  [ "$version" = "$MARKETING_VERSION" ] || problems+=("the archive's version is $version, the settings say $MARKETING_VERSION")
  [ "$build" = "$BUILD_NUMBER" ] || problems+=("the archive's build is $build, the settings say $BUILD_NUMBER")
  case "$check_status:$encryption" in
    0:false|1:"(absent)") ;;
    0:*) problems+=("no encryption library in the program, but ITSAppUsesNonExemptEncryption is $encryption (expected false)") ;;
    1:*) problems+=("the program carries an encryption library, but ITSAppUsesNonExemptEncryption is $encryption (expected absent)") ;;
    *) problems+=("the encryption check could not read the program: $verdict") ;;
  esac

  local tag="testers/$version-$build"
  if ! git -C "$checkout" cat-file -e "$commit^{commit}" 2>/dev/null; then
    problems+=("commit $commit is not in this checkout")
  else
    local tip
    tip="$(git -C "$checkout" ls-remote "$REMOTE" "refs/heads/$BRANCH" | awk '{print $1}')" \
      || problems+=("could not read $REMOTE's $BRANCH")
    if [ -z "${tip:-}" ]; then
      problems+=("$REMOTE has no branch $BRANCH")
    elif ! git -C "$checkout" cat-file -e "$tip^{commit}" 2>/dev/null; then
      problems+=("$REMOTE's $BRANCH is at ${tip:0:11}, which this checkout lacks: git fetch $REMOTE, then run again")
    elif ! git -C "$checkout" merge-base --is-ancestor "$commit" "$tip"; then
      problems+=("commit ${commit:0:11} is not on $REMOTE's $BRANCH (at ${tip:0:11}): push the reviewed commit first")
    else
      echo "  source     on $REMOTE/$BRANCH (at ${tip:0:11})"
    fi
    local tagged
    tagged="$(git -C "$checkout" rev-parse -q --verify "refs/tags/$tag^{commit}" || true)"
    if [ -n "$tagged" ] && [ "$tagged" != "$commit" ]; then
      problems+=("tag $tag already names ${tagged:0:11}")
    fi
    tagged="$(git -C "$checkout" ls-remote "$REMOTE" "refs/tags/$tag" | awk '{print $1}' || true)"
    if [ -n "$tagged" ]; then
      problems+=("$REMOTE already has tag $tag: build $build was sent before; raise BUILD_NUMBER and build again")
    fi
  fi

  if [ ${#problems[@]} -gt 0 ]; then
    echo
    echo "Not sent:"
    printf '  - %s\n' "${problems[@]}"
    return 1
  fi
  if [ -z "$upload_build" ]; then
    echo
    echo "Nothing sent. To upload this build, on the owner's word: $0 --upload-build $build"
    return 0
  fi
  if [ "$upload_build" != "$build" ]; then
    echo
    echo "Nothing sent: --upload-build $upload_build is not this archive's build number ($build)."
    return 1
  fi

  echo
  echo "== upload ($(date '+%H:%M:%S'))"
  local options="$BUILD_DIR/UploadOptions.plist"
  local logs="$BUILD_DIR/logs"
  mkdir -p "$logs"
  cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>manageAppVersionAndBuildNumber</key><false/>
  <key>uploadSymbols</key><false/>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$BUILD_DIR/upload" \
    -exportOptionsPlist "$options" -allowProvisioningUpdates > "$logs/upload.log" 2>&1 \
    || { tail -20 "$logs/upload.log" >&2; fail "the upload failed; nothing was tagged ($logs/upload.log)"; }
  echo "Uploaded build $build. Apple processes it next; App Store Connect reports the result."

  git -C "$checkout" tag -a "$tag" -m "Satsuma 3D $version ($build), sent to TestFlight" "$commit"
  git -C "$checkout" push "$REMOTE" "refs/tags/$tag"
  echo "Tagged ${commit:0:11} as $tag and pushed the tag to $REMOTE."
  echo "Raise BUILD_NUMBER in $settings before the next build."
}

# Everything runs from inside main(), which bash reads whole before running.
main "$@"
exit $?
