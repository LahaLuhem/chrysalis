#!/usr/bin/env bash
#
# Are the Android SDK pins in images/android-sdk/Dockerfile behind Google's repository manifest,
# the same place sdkmanager installs from? Each pin sits in one of three states:
#
#   - platform       tracks the manifest, so any drift gets flagged
#   - cmdline-tools  held behind on purpose, and the hold's way out is re-checked on every run
#   - build-tools    not tracked, it follows what AGP asks for and is printed for information
#                    only (../APPENDIX.md#ndk-cmake-not-baked)
#
# Renovate can't do this. Its customDatasource doesn't parse the manifest XML, and Google's HTML
# pages lag or pre-announce packages you can't install yet. So the weekly android-sdk-freshness
# workflow runs this and keeps one issue up to date. Runs fine locally too.
#
# Exit 0 means the check ran, and whatever it found is in the output and $GITHUB_OUTPUT.
# Exit 2 means it couldn't fetch or parse, so a broken check never reads as "up to date".
#
# Usage: scripts/check-android-sdk.sh
#
set -euo pipefail

# Google's repository manifest (what sdkmanager reads). Revisions are additive and served in
# parallel (2-1..2-4 all live today), so a retired one goes stale silently rather than 404ing.
# 2-4 adds only preview metadata we don't read, hence no reason to move.
manifest_url='https://dl.google.com/android/repository/repository2-3.xml'

# cmdline-tools is held behind the manifest on purpose. rev 23 swapped bin/sdkmanager for a shim
# that hands every install to bin/android, which Google ships as x86-64 only, and the arm64 image
# is built natively (AGENTS.md rule 4). Background: ../APPENDIX.md#no-android-cli.
#
# A hold with no way out is just unverifiable prose, so it carries two exits and both get checked
# below: a rev nobody has assessed shows up, or Google starts serving a Linux arm64 Android CLI.
ct_hold_pin=15859902        # rev 22. Must match the Dockerfile, or this hold is stale.
ct_hold_assessed=16111833   # rev 23, the newest rev the hold has actually been checked against.
ct_hold_clears_url='https://dl.google.com/android/cli/latest/linux_aarch64/android-cli'

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
dockerfile='images/android-sdk/Dockerfile'

# Colour, but only on a terminal (keeps CI logs clean). Mirrors scripts/test.sh.
if [ -t 1 ]; then
  bold=$'\033[1m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'
else
  bold=''; red=''; grn=''; ylw=''; rst=''
fi

die() { printf '%serror:%s %s\n' "$red" "$rst" "$1" >&2; exit 2; }

status() { if [ "$1" = true ]; then printf '%sbehind%s' "$ylw" "$rst"; else printf '%sok%s' "$grn" "$rst"; fi; }

# Package extraction from a manifest. build-tools look like "build-tools;X.Y.Z" and platforms
# like "platforms;android-NN". That NN is numeric, so codename previews such as android-CANARY
# are excluded by construction.
build_tools_of() {
  printf '%s' "$1" | grep -oE 'path="build-tools;[0-9]+\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*build-tools;//; s/"$//' | sort -uV || true
}
platforms_of() {
  printf '%s' "$1" | grep -oE 'path="platforms;android-[0-9]+"' \
    | sed -E 's/.*android-//; s/"$//' | sort -un || true
}
# cmdline-tools has no version string, just a build number in its download name. They only go up,
# so the highest one in the manifest is the newest.
cmdline_tools_of() {
  printf '%s' "$1" | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' \
    | sed -E 's/.*-//; s/_latest\.zip$//' | sort -un || true
}

command -v curl >/dev/null 2>&1 || die 'curl is required'

# --- Latest stable, from the manifest -------------------------------------------------
if ! xml="$(curl -fsSL "$manifest_url")"; then
  die "could not fetch $manifest_url"
fi

all_pl="$(platforms_of "$xml")"
all_ct="$(cmdline_tools_of "$xml")"
latest_pl="$(printf '%s\n' "$all_pl" | tail -1)"
latest_ct="$(printf '%s\n' "$all_ct" | tail -1)"
newest_bt="$(build_tools_of "$xml" | tail -1)"

[ -n "$newest_bt" ] || die "no build-tools found in the manifest (did its format change?)"
[ -n "$latest_pl" ] || die "no platforms found in the manifest (did its format change?)"
[ -n "$latest_ct" ] || die "no cmdline-tools found in the manifest (did its format change?)"

# --- Is the revision we read still being fed? -----------------------------------------
# Probe upward and compare the newest package each revision advertises. build-tools is in that
# comparison purely as a canary (its revisions land far more often than platforms), not because
# anything is pinned against it.
rev="${manifest_url##*repository2-}"; rev="${rev%.xml}"
case "$rev" in '' | *[!0-9]*) die "manifest_url must look like .../repository2-N.xml" ;; esac

probe="$rev"; newer_url=''
while [ "$((probe - rev))" -lt 6 ]; do
  probe=$((probe + 1))
  candidate="${manifest_url%repository2-*.xml}repository2-${probe}.xml"
  curl -fsIL -o /dev/null "$candidate" 2>/dev/null || break
  newer_url="$candidate"
done

if [ -n "$newer_url" ]; then
  newer_xml="$(curl -fsSL "$newer_url")" \
    || die "$newer_url serves but could not be fetched to compare against"
  newer_rev_bt="$(build_tools_of "$newer_xml" | tail -1)"
  newer_rev_pl="$(platforms_of "$newer_xml" | tail -1)"
  if [ "$newer_rev_bt" != "$newest_bt" ] || [ "$newer_rev_pl" != "$latest_pl" ]; then
    die "$manifest_url is stale: $newer_url has build-tools $newer_rev_bt / android-$newer_rev_pl, we read $newest_bt / android-$latest_pl. Point manifest_url at the newer revision."
  fi
fi

# --- Pinned, from the Dockerfile ------------------------------------------------------
# Matched by var name so grouping the ENV lines later doesn't break the read.
pinned_bt="$(grep -oE 'ANDROID_BUILD_TOOLS_VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$dockerfile" | head -1 | cut -d= -f2- || true)"
pinned_pl="$(grep -oE 'ANDROID_PLATFORM_VERSION=[0-9]+' "$dockerfile" | head -1 | cut -d= -f2- || true)"
pinned_ct="$(grep -oE 'ANDROID_SDK_TOOLS_VERSION=[0-9]+' "$dockerfile" | head -1 | cut -d= -f2- || true)"

[ -n "$pinned_bt" ] || die "ANDROID_BUILD_TOOLS_VERSION not found in $dockerfile"
[ -n "$pinned_pl" ] || die "ANDROID_PLATFORM_VERSION not found in $dockerfile"
[ -n "$pinned_ct" ] || die "ANDROID_SDK_TOOLS_VERSION not found in $dockerfile"

# Comparing against the newest misses the pin going away entirely, which the Dockerfile would hit
# as a 404 on its next build.
printf '%s\n' "$all_pl" | grep -qx "$pinned_pl" \
  || die "pinned platform android-$pinned_pl is no longer in the manifest"
printf '%s\n' "$all_ct" | grep -qx "$pinned_ct" \
  || die "pinned cmdline-tools $pinned_ct is no longer in the manifest"

# --- Compare --------------------------------------------------------------------------
pl_behind=false
if [ "$pinned_pl" -lt "$latest_pl" ]; then pl_behind=true; fi

# For a held pin the question isn't "is something newer out", it's "does the hold still stand".
if [ "$pinned_ct" != "$ct_hold_pin" ]; then
  die "cmdline-tools is pinned to $pinned_ct but the hold here covers $ct_hold_pin. Update the hold or drop it."
fi

ct_state=held
if [ "$latest_ct" -gt "$ct_hold_assessed" ]; then
  ct_state=unassessed
else
  # No -f: we want the status code for a 404 too, and only a dead connection to be an error.
  arm_code="$(curl -sI -o /dev/null -w '%{http_code}' "$ct_hold_clears_url" || true)"
  case "$arm_code" in
    404) ;;
    200) ct_state=clearable ;;
    *) die "$ct_hold_clears_url answered $arm_code, so the hold could not be re-checked" ;;
  esac
fi

case "$ct_state" in
  held)
    ct_note="${grn}held${rst} (still no Linux arm64 Android CLI)"
    ct_why="rev 23 installs through a binary the native arm64 build can't run (../APPENDIX.md#no-android-cli)"
    ;;
  clearable)
    ct_note="${ylw}hold can lift${rst} (Google now serves a Linux arm64 Android CLI)"
    ct_why=''
    ;;
  unassessed)
    ct_note="${ylw}needs a look${rst} (newer than the $ct_hold_assessed the hold was checked against)"
    ct_why=''
    ;;
esac

printf '%sAndroid SDK pins vs %s%s\n' "$bold" "$manifest_url" "$rst"
printf '  platform       pinned %-11s latest %-11s %s\n' "android-$pinned_pl" "android-$latest_pl" "$(status "$pl_behind")"
printf '  build-tools    pinned %-11s follows AGP, not the manifest (newest there: %s)\n' "$pinned_bt" "$newest_bt"
printf '  cmdline-tools  pinned %-11s latest %-11s %s\n' "$pinned_ct" "$latest_ct" "$ct_note"
if [ -n "$ct_why" ]; then
  printf '                 %s\n' "$ct_why"
fi

# --- Verdict --------------------------------------------------------------------------
tick='`'
appendix='../blob/master/APPENDIX.md'
# "behind" is the workflow's name for "a human should look at this", which is why a hold with a
# way out counts even though its pin hasn't moved.
behind=false; details=''
if [ "$pl_behind" = true ]; then
  behind=true
  details="${details}- platform (${tick}ANDROID_PLATFORM_VERSION${tick}): ${tick}android-${pinned_pl}${tick} -> ${tick}android-${latest_pl}${tick}"$'\n'
fi
case "$ct_state" in
  clearable)
    behind=true
    details="${details}- cmdline-tools (${tick}ANDROID_SDK_TOOLS_VERSION${tick}): Google now serves a Linux arm64 Android CLI, so the hold at ${tick}${pinned_ct}${tick} can be re-checked ([why it's held](${appendix}#no-android-cli))"$'\n'
    ;;
  unassessed)
    behind=true
    details="${details}- cmdline-tools (${tick}ANDROID_SDK_TOOLS_VERSION${tick}): rev ${tick}${latest_ct}${tick} is newer than the ${tick}${ct_hold_assessed}${tick} this hold was checked against. Does its ${tick}bin/sdkmanager${tick} still start a JVM?"$'\n'
    ;;
esac

# Hand the verdict to the workflow when running under Actions.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'behind=%s\n' "$behind"
    printf 'details<<__EOF__\n%s__EOF__\n' "$details"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$behind" = true ]; then
  printf '\n%ssomething needs a look%s (see above, pins live in %s)\n' "$ylw" "$rst" "$dockerfile"
else
  printf '\n%snothing to do%s\n' "$grn" "$rst"
fi
