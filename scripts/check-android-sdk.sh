#!/usr/bin/env bash
#
# Check whether the Android SDK pins in images/android-sdk/Dockerfile are behind the
# latest stable packages Google publishes. build-tools and the platform (compileSdk)
# are compared against Google's repository manifest, the same source sdkmanager installs
# from. cmdline-tools is pinned by an opaque build number rather than a version, so it's
# out of scope here and bumped by hand.
#
# build-tools are capped at the newest stable platform's generation: a generation can ship
# stable before its platform does (37.0.0 landed while API 37 was still android-CANARY),
# and build-tools ahead of the platform we install buy nothing.
#
# Renovate can't track these (its customDatasource doesn't parse the manifest XML, and
# Google's HTML pages lag or pre-announce packages that aren't installable yet), so this
# stands in for a Renovate "update available" PR. The weekly android-sdk-freshness
# workflow runs it and opens an issue on drift; it also runs fine locally.
#
# Exit 0 = ran fine (drift, if any, is in the output and $GITHUB_OUTPUT); exit 2 =
# couldn't fetch or parse (e.g. Google moved the manifest URL). It never reports "up to
# date" on failure, so a broken check is visible rather than silent.
#
# Usage: scripts/check-android-sdk.sh
#
set -euo pipefail

# Google's repository manifest (what sdkmanager reads). Revisions are additive and stay
# live in parallel (2-1..2-4 all serve today) so old clients keep working, which means a
# retired revision would go stale silently rather than 404. 2-4 currently carries the same
# package set as 2-3, differing only in preview metadata we don't read.
manifest_url='https://dl.google.com/android/repository/repository2-3.xml'

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

# newer <a> <b>: true when <b> is a strictly newer version than <a>.
newer() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$2" ]; }

status() { if [ "$1" = true ]; then printf '%sbehind%s' "$ylw" "$rst"; else printf '%sok%s' "$grn" "$rst"; fi; }

command -v curl >/dev/null 2>&1 || die 'curl is required'

# --- Latest stable, from the manifest -------------------------------------------------
# build-tools are "build-tools;X.Y.Z"; platforms are "platforms;android-NN" (numeric, so
# codename previews like android-CANARY are excluded by construction). The platform is read
# first because it sets the generation cap for build-tools below.
if ! xml="$(curl -fsSL "$manifest_url")"; then
  die "could not fetch $manifest_url"
fi

latest_pl="$(printf '%s' "$xml" \
  | grep -oE 'path="platforms;android-[0-9]+"' \
  | sed -E 's/.*android-//; s/"$//' | sort -un | tail -1 || true)"
all_bt="$(printf '%s' "$xml" \
  | grep -oE 'path="build-tools;[0-9]+\.[0-9]+\.[0-9]+"' \
  | sed -E 's/.*build-tools;//; s/"$//' | sort -uV || true)"

[ -n "$all_bt" ] || die "no build-tools found in the manifest (did its format change?)"
[ -n "$latest_pl" ] || die "no platforms found in the manifest (did its format change?)"

# Cap at the platform generation (see the header). newest_bt is kept only to report what
# is being held back, so a capped result doesn't read as a stale check.
newest_bt="$(printf '%s\n' "$all_bt" | tail -1)"
latest_bt="$(printf '%s\n' "$all_bt" | awk -F. -v max="$latest_pl" '$1 <= max' | tail -1)"

[ -n "$latest_bt" ] || die "no build-tools at or below android-$latest_pl (newest is $newest_bt)"

# --- Pinned, from the Dockerfile ------------------------------------------------------
# Matched by var name so grouping the ENV lines later doesn't break the read.
pinned_bt="$(grep -oE 'ANDROID_BUILD_TOOLS_VERSION=[0-9]+\.[0-9]+\.[0-9]+' "$dockerfile" | head -1 | cut -d= -f2- || true)"
pinned_pl="$(grep -oE 'ANDROID_PLATFORM_VERSION=[0-9]+' "$dockerfile" | head -1 | cut -d= -f2- || true)"

[ -n "$pinned_bt" ] || die "ANDROID_BUILD_TOOLS_VERSION not found in $dockerfile"
[ -n "$pinned_pl" ] || die "ANDROID_PLATFORM_VERSION not found in $dockerfile"

# --- Compare --------------------------------------------------------------------------
bt_behind=false; pl_behind=false
if newer "$pinned_bt" "$latest_bt"; then bt_behind=true; fi
if [ "$pinned_pl" -lt "$latest_pl" ]; then pl_behind=true; fi

printf '%sAndroid SDK pins vs %s%s\n' "$bold" "$manifest_url" "$rst"
printf '  build-tools    pinned %-11s latest %-11s %s\n' "$pinned_bt" "$latest_bt" "$(status "$bt_behind")"
if [ "$newest_bt" != "$latest_bt" ]; then
  printf '                 %s is newer but held back until android-%s is stable\n' \
    "$newest_bt" "${newest_bt%%.*}"
fi
printf '  platform       pinned %-11s latest %-11s %s\n' "android-$pinned_pl" "android-$latest_pl" "$(status "$pl_behind")"
printf '  cmdline-tools  pinned by build number, checked manually\n'

# --- Verdict --------------------------------------------------------------------------
tick='`'
behind=false; details=''
if [ "$bt_behind" = true ]; then
  behind=true
  details="${details}- build-tools: ${tick}${pinned_bt}${tick} -> ${tick}${latest_bt}${tick}"$'\n'
fi
if [ "$pl_behind" = true ]; then
  behind=true
  details="${details}- platform: ${tick}android-${pinned_pl}${tick} -> ${tick}android-${latest_pl}${tick}"$'\n'
fi

# Hand the verdict to the workflow when running under Actions.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'behind=%s\n' "$behind"
    printf 'details<<__EOF__\n%s__EOF__\n' "$details"
  } >> "$GITHUB_OUTPUT"
fi

if [ "$behind" = true ]; then
  printf '\n%supdate available%s (bump them in %s)\n' "$ylw" "$rst" "$dockerfile"
else
  printf '\n%sall Android SDK pins current%s\n' "$grn" "$rst"
fi
