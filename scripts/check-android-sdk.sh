#!/usr/bin/env bash
#
# Check whether the Android SDK platform pin (compileSdk) in images/android-sdk/Dockerfile is
# behind the latest stable platform in Google's repository manifest, the same source
# sdkmanager installs from. Two pins stay out of scope: cmdline-tools, pinned by an opaque
# build number rather than a version, and build-tools.
#
# build-tools deliberately does NOT track the manifest. AGP requests a specific revision and
# downloads it mid-build when it's absent, so the pin's only job is to match that request and
# keep consumer builds hermetic. Flutter 3.44.8 ships AGP 9.0.1, which wants 36.0.0, so
# pinning the manifest's newest (36.1.0, or 37.0.0) would just make every consumer build
# fetch 36.0.0 anyway. Bump it when Flutter's AGP moves, verified with `scripts/test.sh apk`.
#
# Renovate can't track these (its customDatasource doesn't parse the manifest XML, and
# Google's HTML pages lag or pre-announce packages that aren't installable yet), so this
# stands in for a Renovate "update available" PR. The weekly android-sdk-freshness
# workflow runs it and opens an issue on drift; it also runs fine locally.
#
# Exit 0 = ran fine (drift, if any, is in the output and $GITHUB_OUTPUT); exit 2 = couldn't
# fetch or parse, or the manifest revision we read has gone stale. It never reports "up to
# date" on failure, so a broken check is visible rather than silent.
#
# Usage: scripts/check-android-sdk.sh
#
set -euo pipefail

# Google's repository manifest (what sdkmanager reads). Revisions are additive and stay live
# in parallel (2-1..2-4 all serve today) so old clients keep working; the staleness probe
# below is what catches this one being retired. 2-4 currently carries the same package set,
# differing only in preview metadata we don't read, so there's nothing to gain by moving.
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

command -v curl >/dev/null 2>&1 || die 'curl is required'

# --- Latest stable, from the manifest -------------------------------------------------
if ! xml="$(curl -fsSL "$manifest_url")"; then
  die "could not fetch $manifest_url"
fi

latest_pl="$(latest_platform_of "$xml")"
newest_bt="$(build_tools_of "$xml" | tail -1)"

[ -n "$newest_bt" ] || die "no build-tools found in the manifest (did its format change?)"
[ -n "$latest_pl" ] || die "no platforms found in the manifest (did its format change?)"

# --- Is the revision we read still being fed? -----------------------------------------
# Revisions are additive and served in parallel, so a retired one goes stale silently instead
# of 404ing. Probe upward from the one we read and compare the newest package each advertises.
# build-tools is in that comparison purely as a staleness canary (its revisions land far more
# often than platforms do), not because anything is pinned against it.
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

[ -n "$pinned_bt" ] || die "ANDROID_BUILD_TOOLS_VERSION not found in $dockerfile"
[ -n "$pinned_pl" ] || die "ANDROID_PLATFORM_VERSION not found in $dockerfile"

# --- Compare --------------------------------------------------------------------------
pl_behind=false
if [ "$pinned_pl" -lt "$latest_pl" ]; then pl_behind=true; fi

printf '%sAndroid SDK pins vs %s%s\n' "$bold" "$manifest_url" "$rst"
printf '  platform       pinned %-11s latest %-11s %s\n' "android-$pinned_pl" "android-$latest_pl" "$(status "$pl_behind")"
printf '  build-tools    pinned %-11s follows AGP, not the manifest (newest there: %s)\n' "$pinned_bt" "$newest_bt"
printf '  cmdline-tools  pinned by build number, checked manually\n'

# --- Verdict --------------------------------------------------------------------------
tick='`'
behind=false; details=''
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
