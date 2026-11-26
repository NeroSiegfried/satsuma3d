#!/bin/bash
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Send one tester build to App Store Connect, on the owner's word (ROUND5 8L, L4; gate G4).
#
#     release/ios/upload_testflight.sh [<settings-file>]                       # prints, sends nothing
#     release/ios/upload_testflight.sh --upload-build <n> [<settings-file>]    # uploads build <n>
#     release/ios/upload_testflight.sh --allow-provisioning-updates --upload-build <n> [<settings-file>]
#
# Takes the archive `build_testflight.sh` made (`<build dir>/Satsuma3D.xcarchive`, with its exported
# `.ipa` beside it, so the export has run) and prints what it would send: the app, its version,
# build number, source commit, the encryption key, the owner's claim and the three groups of
# `check_no_encryption_library.py` on the archived app. Then it checks:
#
# - the archive's bundle id, version and build number are the settings' (`testflight.env`);
# - the key is the one the rule writes (ROUND5 8M.2, E7): `ITSAppUsesNonExemptEncryption` false only
#   when the check finds no general encryption library and nothing unreviewed and the settings carry
#   the owner's `ENCRYPTION_CLAIM=exempt`; no key in every other case. Anything else, a program the
#   check cannot read or a claim it does not know refuses. The check's three groups are printed;
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
# The upload signs for App Store Connect again. Without a distribution certificate in this Mac's
# keychain that needs Xcode's account (cloud signing), which `xcodebuild` uses only with
# `-allowProvisioningUpdates`; that flag also lets it create or change certificates, profiles and App
# IDs in the developer account. It is passed only with `--allow-provisioning-updates`, which is the
# owner's to give (no agent passes it).
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
  local upload_build="" settings="" account=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --upload-build)
        [ $# -ge 2 ] || fail "--upload-build needs the build number"
        upload_build="$2"
        shift 2
        ;;
      --allow-provisioning-updates)
        account=yes
        shift
        ;;
      -h|--help)
        sed -n '8,10p' "$0" | sed 's/^# \{0,4\}//'
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
  ENCRYPTION_CLAIM=ask
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
  local check_status=0 output verdict expected
  output="$(python3 -B "$checkout/release/ios/check_no_encryption_library.py" --claim "$ENCRYPTION_CLAIM" "$app" 2>&1)" \
    || check_status=$?
  verdict="$(echo "$output" | tail -1 | sed "s|: $app\$||")"
  echo "  encryption claim  $ENCRYPTION_CLAIM (testflight.env)"
  echo "  encryption check  $verdict"
  echo "$output" | sed -n '/^1\. /,/^3\. /p; /^   /p' | awk '!seen[$0]++' | sed "s|$app/||; s|^|    |"
  expected="$(echo "$output" | sed -n 's/^ITSAppUsesNonExemptEncryption: //p' | cut -d' ' -f1)"

  local problems=()
  [ "$bundle_id" = "$BUNDLE_ID" ] || problems+=("the archive's bundle id is $bundle_id, the settings say $BUNDLE_ID")
  [ "$version" = "$MARKETING_VERSION" ] || problems+=("the archive's version is $version, the settings say $MARKETING_VERSION")
  [ "$build" = "$BUILD_NUMBER" ] || problems+=("the archive's build is $build, the settings say $BUILD_NUMBER")
  case "$check_status" in
    0|1|3)
      [ "$expected" = absent ] && expected="(absent)"
      [ "$encryption" = "$expected" ] \
        || problems+=("ITSAppUsesNonExemptEncryption is $encryption, but the rule writes $expected for \"$verdict\" with ENCRYPTION_CLAIM=$ENCRYPTION_CLAIM") ;;
    *) problems+=("the encryption check could not read the program or the claim: $verdict") ;;
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
  # The developer account only on the owner's flag (see the top of this file).
  local account_args=()
  [ -n "$account" ] && account_args=(-allowProvisioningUpdates)
  xcodebuild -exportArchive -archivePath "$archive" -exportPath "$BUILD_DIR/upload" \
    -exportOptionsPlist "$options" "${account_args[@]+"${account_args[@]}"}" > "$logs/upload.log" 2>&1 \
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
