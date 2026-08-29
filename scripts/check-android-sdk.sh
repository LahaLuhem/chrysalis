#!/usr/bin/env bash
#
# Check whether the platform and cmdline-tools pins in images/android-sdk/Dockerfile are behind
# Google's repository manifest, the same source sdkmanager installs from. build-tools stays out of
# scope on purpose: it follows what AGP asks for, not the manifest, so flagging it here would
# actively mislead (../APPENDIX.md#ndk-cmake-not-baked).
#
# Renovate can't track this (its customDatasource doesn't parse the manifest XML, and Google's
# HTML pages lag or pre-announce packages that aren't installable yet), so this stands in for a
# Renovate "update available" PR. The weekly android-sdk-freshness workflow runs it and opens an
# issue on drift; it also runs fine locally.
#
# Exit 0 = ran fine (drift, if any, is in the output and $GITHUB_OUTPUT); exit 2 = couldn't fetch
# or parse, or the revision we read has gone stale, so a broken check never reads as "up to date".
#
# Usage: scripts/check-android-sdk.sh
#
set -euo pipefail

# Google's repository manifest (what sdkmanager reads). Revisions are additive and served in
# parallel (2-1..2-4 all live today), so a retired one goes stale silently rather than 404ing.
# 2-4 adds only preview metadata we don't read, hence no reason to move.
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

status() { if [ "$1" = true ]; then printf '%sbehind%s' "$ylw" "$rst"; else printf '%sok%s' "$grn" "$rst"; fi; }

# Package extraction from a manifest. build-tools are "build-tools;X.Y.Z"; platforms are
# "platforms;android-NN" (numeric, so codename previews like android-CANARY are excluded by
# construction).
build_tools_of() {
  printf '%s' "$1" | grep -oE 'path="build-tools;[0-9]+\.[0-9]+\.[0-9]+"' \
    | sed -E 's/.*build-tools;//; s/"$//' | sort -uV || true
}
latest_platform_of() {
  printf '%s' "$1" | grep -oE 'path="platforms;android-[0-9]+"' \
    | sed -E 's/.*android-//; s/"$//' | sort -un | tail -1 || true
}
# cmdline-tools has no version string, just a build number in its download name. They only go up,
# so the highest one in the manifest is the newest.
latest_cmdline_tools_of() {
  printf '%s' "$1" | grep -oE 'commandlinetools-linux-[0-9]+_latest\.zip' \
    | sed -E 's/.*-//; s/_latest\.zip$//' | sort -un | tail -1 || true
}

command -v curl >/dev/null 2>&1 || die 'curl is required'

# --- Latest stable, from the manifest -------------------------------------------------
if ! xml="$(curl -fsSL "$manifest_url")"; then
  die "could not fetch $manifest_url"
fi

latest_pl="$(latest_platform_of "$xml")"
newest_bt="$(build_tools_of "$xml" | tail -1)"
latest_ct="$(latest_cmdline_tools_of "$xml")"

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
  newer_rev_pl="$(latest_platform_of "$newer_xml")"
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

# --- Compare --------------------------------------------------------------------------
pl_behind=false
if [ "$pinned_pl" -lt "$latest_pl" ]; then pl_behind=true; fi
ct_behind=false
if [ "$pinned_ct" -lt "$latest_ct" ]; then ct_behind=true; fi

printf '%sAndroid SDK pins vs %s%s\n' "$bold" "$manifest_url" "$rst"
printf '  platform       pinned %-11s latest %-11s %s\n' "android-$pinned_pl" "android-$latest_pl" "$(status "$pl_behind")"
printf '  build-tools    pinned %-11s follows AGP, not the manifest (newest there: %s)\n' "$pinned_bt" "$newest_bt"
printf '  cmdline-tools  pinned %-11s latest %-11s %s\n' "$pinned_ct" "$latest_ct" "$(status "$ct_behind")"

# --- Verdict --------------------------------------------------------------------------
tick='`'
behind=false; details=''
if [ "$pl_behind" = true ]; then
  behind=true
  details="${details}- platform: ${tick}android-${pinned_pl}${tick} -> ${tick}android-${latest_pl}${tick}"$'\n'
fi
if [ "$ct_behind" = true ]; then
  behind=true
  details="${details}- cmdline-tools: ${tick}${pinned_ct}${tick} -> ${tick}${latest_ct}${tick}"$'\n'
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
