#!/bin/sh
# SPDX-FileCopyrightText: 2026 Blender Authors
#
# SPDX-License-Identifier: GPL-2.0-or-later

# Run before every push of this fork (ROUND5 8I.4, decision 48). It only reads: it never pushes,
# fetches or changes anything.
#
#     release/ios/check_publishable.sh [<base> [<tip>]]
#
# Checks every commit above <base> (default: 0beedec1782, the Blender commit this fork starts
# from) up to <tip> (default: HEAD, the commit a push would publish) and fails when:
#
# 1. a commit adds or changes a file through Git LFS: its blob is an LFS pointer, or the
#    `.gitattributes` of that commit send its path through the `lfs` filter. The public fork
#    cannot hold LFS objects (decision 44); a binary that must exist gets its own path with
#    `-filter -diff -merge`.
# 2. a commit's author or committer is not the repository's `user.email`, or that address is not
#    a GitHub no-reply address.
# 3. a file changed in that range, or a commit message, holds a home path or a private
#    identifier of this Mac: the home folder, the user name in a `/Users/…` path, and the team
#    ids and device ids in the local provisioning profiles. Those are read here, from the Mac,
#    and never written anywhere.
#
# Exits 0 when everything passes, 1 otherwise, printing each problem.

set -u

base="${1:-0beedec1782}"
tip="${2:-HEAD}"
root="$(git rev-parse --show-toplevel)" || exit 1
cd "$root" || exit 1
for commit in "$base" "$tip"; do
  git rev-parse --verify --quiet "$commit^{commit}" >/dev/null || {
    echo "check_publishable: no commit $commit"
    exit 1
  }
done

failures=0
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

commits="$(git rev-list "$base..$tip")"
count="$(printf '%s\n' "$commits" | grep -c .)"
echo "Checking $count commits above $base"

# 1. Git LFS.
lfs_checked=0
for commit in $commits; do
  git diff-tree --no-commit-id -r --diff-filter=AMT --no-renames --raw "$commit" |
    while IFS= read -r line; do
      blob="$(printf '%s' "$line" | awk '{print $4}')"
      path="$(printf '%s' "$line" | cut -f2-)"
      if [ "$(git check-attr --source="$commit" filter -- "$path" | sed 's/.*: filter: //')" = "lfs" ]; then
        echo "FAIL: $(git rev-parse --short "$commit") sends $path through Git LFS (.gitattributes)"
      fi
      size="$(git cat-file -s "$blob" 2>/dev/null || echo 0)"
      if [ "$size" -lt 1024 ] &&
          git cat-file -p "$blob" 2>/dev/null | head -n 1 | grep -q '^version https://git-lfs'; then
        echo "FAIL: $(git rev-parse --short "$commit") stores $path as a Git LFS pointer"
      fi
    done
  lfs_checked=$((lfs_checked + 1))
done >"${TMPDIR:-/tmp}/check_publishable_lfs.$$"
if [ -s "${TMPDIR:-/tmp}/check_publishable_lfs.$$" ]; then
  cat "${TMPDIR:-/tmp}/check_publishable_lfs.$$"
  failures=$((failures + $(grep -c . "${TMPDIR:-/tmp}/check_publishable_lfs.$$")))
fi
rm -f "${TMPDIR:-/tmp}/check_publishable_lfs.$$"
echo "Git LFS: $lfs_checked commits read"

# 2. Identity.
email="$(git config user.email)"
case "$email" in
  *@users.noreply.github.com) ;;
  *) fail "the repository's user.email is not a GitHub no-reply address" ;;
esac
others="$(git log --format='%h %ae%n%h %ce' "$base..$tip" | awk -v email="$email" '$2 != email')"
if [ -n "$others" ]; then
  printf '%s\n' "$others" | while IFS= read -r line; do
    echo "FAIL: commit ${line%% *} has an author or committer other than user.email"
  done
  failures=$((failures + $(printf '%s\n' "$others" | grep -c .)))
fi
echo "Identity: every author and committer checked"

# 3. Private strings. Gathered from this Mac; printed only by kind.
patterns="${TMPDIR:-/tmp}/check_publishable_patterns.$$"
: >"$patterns"
printf '%s\n' "$HOME" >>"$patterns"
user_name="$(basename "$HOME")"
[ -n "$user_name" ] && printf '/Users/%s\n' "$user_name" >>"$patterns"
for profile in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles/"*.mobileprovision \
    "$HOME/Library/MobileDevice/Provisioning Profiles/"*.mobileprovision; do
  [ -f "$profile" ] || continue
  values="$(security cms -D -i "$profile" 2>/dev/null | /usr/bin/python3 -I -c '
import plistlib, sys
data = plistlib.loads(sys.stdin.buffer.read())
for key in ("TeamIdentifier", "ProvisionedDevices"):
    for value in data.get(key, []):
        print(value)
')"
  if [ -z "$values" ]; then
    # A profile that cannot be read would let its ids through unchecked.
    fail "could not read the team and device ids of a provisioning profile: $(basename "$profile")"
    continue
  fi
  printf '%s\n' "$values" >>"$patterns"
done
sort -u -o "$patterns" "$patterns"
echo "Private strings: $(grep -c . "$patterns") gathered from this Mac"

files="$(git diff --name-only --diff-filter=AMT "$base" "$tip")"
if [ -n "$files" ]; then
  hits="$(printf '%s\n' "$files" | tr '\n' '\0' |
    xargs -0 git grep -l -F -f "$patterns" "$tip" -- 2>/dev/null | sed "s/^$tip://")"
  generic="$(printf '%s\n' "$files" | tr '\n' '\0' |
    xargs -0 git grep -l -E '/Users/[A-Za-z0-9._-]+/' "$tip" -- 2>/dev/null | sed "s/^$tip://")"
  for path in $hits; do
    fail "$path holds a private string of this Mac (home path, team id or device id)"
  done
  for path in $generic; do
    case " $hits " in *" $path "*) continue ;; esac
    fail "$path holds a home path (/Users/<name>/)"
  done
fi
for commit in $commits; do
  message="$(git log -1 --format=%B "$commit")"
  if printf '%s\n' "$message" | grep -q -F -f "$patterns" ||
      printf '%s\n' "$message" | grep -q -E '/Users/[A-Za-z0-9._-]+/'; then
    fail "the message of $(git rev-parse --short "$commit") holds a home path, team id or device id"
  fi
done
rm -f "$patterns"
echo "Private strings: $(printf '%s\n' "$files" | grep -c .) changed files and $count messages read"

if [ "$failures" -ne 0 ]; then
  echo "Not publishable: $failures problems"
  exit 1
fi
echo "Publishable"
exit 0
