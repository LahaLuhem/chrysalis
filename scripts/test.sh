#!/usr/bin/env bash
#
# Local test suite for chrysalis (a Docker image build/publish repo).
#
#   lint       Static checks, no Docker: hadolint, actionlint, shellcheck, versions.env.
#   image      Build android-sdk + flutter for the host arch and assert their contents
#              with container-structure-test, plus a version-match and arch invariant.
#   multiarch  Build android-sdk for amd64 + arm64 (amd64 emulated) and assert the
#              resulting manifest carries both arches. Slow; opt-in, not part of `all`.
#   all        lint + image.
#
# Usage: scripts/test.sh [lint|image|multiarch|all]   (default: all)
#
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Colour, but only on a terminal (keeps CI logs clean).
if [ -t 1 ]; then
  bold=$'\033[1m'; red=$'\033[31m'; grn=$'\033[32m'; ylw=$'\033[33m'; rst=$'\033[0m'
else
  bold=''; red=''; grn=''; ylw=''; rst=''
fi

failures=0
section() { printf '\n%s==> %s%s\n' "$bold" "$1" "$rst"; }
ok()      { printf '%s ok %s  %s\n' "$grn" "$rst" "$1"; }
bad()     { printf '%sFAIL%s  %s\n' "$red" "$rst" "$1"; failures=$((failures + 1)); }
skip()    { printf '%sSKIP%s  %s\n' "$ylw" "$rst" "$1"; }

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '%smissing tool:%s %s  (install: %s)\n' "$red" "$rst" "$1" "$2"
  exit 2
}

flutter_version() { grep -E '^FLUTTER_VERSION=' versions.env | cut -d= -f2- || true; }

check_versions_env() {
  local f='versions.env' tag ver
  if [ ! -f "$f" ]; then bad "$f is missing"; return; fi
  tag="$(grep -E '^DOCKER_TAG=' "$f" | cut -d= -f2- || true)"
  ver="$(flutter_version)"
  if [ -n "$tag" ]; then ok "DOCKER_TAG=$tag"; else bad "DOCKER_TAG missing"; fi
  if printf '%s' "$ver" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    ok "FLUTTER_VERSION=$ver"
  else
    bad "FLUTTER_VERSION is not x.y.z: '$ver'"
  fi
}

run_lint() {
  need hadolint   'brew install hadolint'
  need actionlint 'brew install actionlint'
  need shellcheck 'brew install shellcheck'

  section 'hadolint (Dockerfiles)'
  if hadolint sdk/Dockerfile.android sdk/Dockerfile.flutter; then ok 'Dockerfiles clean'; else bad 'hadolint'; fi

  section 'actionlint (workflows)'
  if actionlint .github/workflows/*.yml; then ok 'workflows clean'; else bad 'actionlint'; fi

  section 'shellcheck (shell scripts)'
  if shellcheck scripts/*.sh; then ok 'scripts clean'; else bad 'shellcheck'; fi

  section 'versions.env sanity'
  check_versions_env
}

# Builds for the host architecture only; CI covers both arches via the matrix.
run_image() {
  need container-structure-test 'brew install container-structure-test'
  if ! command -v docker >/dev/null 2>&1; then
    printf '%smissing tool:%s docker  (start OrbStack / Docker Desktop)\n' "$red" "$rst"; exit 2
  fi

  # container-structure-test talks to the Docker API directly and defaults to
  # /var/run/docker.sock; point it at the CLI's configured endpoint (e.g. OrbStack).
  if [ -z "${DOCKER_HOST:-}" ]; then
    DOCKER_HOST="$(docker context inspect -f '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    [ -n "$DOCKER_HOST" ] && export DOCKER_HOST
  fi

  local ver arch base log
  ver="$(flutter_version)"
  arch="$(uname -m)"
  base='ghcr.io/lahaluhem/android-sdk:latest'
  log="$(mktemp)"
  local android_img='chrysalis-test/android-sdk:local'
  local flutter_img='chrysalis-test/flutter:local'

  section 'build android-sdk (host arch)'
  if docker buildx build --load -t "$android_img" -f sdk/Dockerfile.android . >"$log" 2>&1; then
    ok 'built android-sdk'
  else
    bad 'android-sdk build'; tail -n 30 "$log"; rm -f "$log"; return
  fi

  section 'build flutter (host arch)'
  if docker buildx build --load \
       --build-context "$base=docker-image://$android_img" \
       --build-arg "flutter_version=$ver" \
       -t "$flutter_img" -f sdk/Dockerfile.flutter . >"$log" 2>&1; then
    ok 'built flutter'
  else
    bad 'flutter build'; tail -n 30 "$log"; rm -f "$log"; return
  fi
  rm -f "$log"

  section 'container-structure-test: android-sdk'
  if container-structure-test test --image "$android_img" --config test/structure/android-sdk.yaml; then
    ok 'android-sdk structure'
  else
    bad 'android-sdk structure'
  fi

  section 'container-structure-test: flutter'
  if container-structure-test test --image "$flutter_img" --config test/structure/flutter.yaml; then
    ok 'flutter structure'
  else
    bad 'flutter structure'
  fi

  section "flutter version matches versions.env ($ver)"
  if docker run --rm "$flutter_img" flutter --version 2>/dev/null | grep -q "Flutter $ver"; then
    ok "image reports Flutter $ver"
  else
    bad "image does not report Flutter $ver"
  fi

  # The Android emulator is x86_64-only; sdk/Dockerfile.android skips it on arm64.
  section 'android emulator arch invariant'
  if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
    if docker run --rm "$android_img" sh -c '! test -d /opt/android-sdk-linux/emulator'; then
      ok 'emulator absent on arm64 (expected)'
    else
      bad 'emulator present on arm64 (the uname guard is broken)'
    fi
  else
    if docker run --rm "$android_img" sh -c 'test -d /opt/android-sdk-linux/emulator'; then
      ok 'emulator present on amd64 (expected)'
    else
      bad 'emulator absent on amd64 (unexpected)'
    fi
  fi
}

# Builds android-sdk for both arches into an OCI archive (no registry needed) and
# asserts the manifest carries linux/amd64 + linux/arm64. amd64 is emulated on an
# arm64 host, so this is slow and kept out of `all`. flutter's amd64 build is left to
# CI (emulating it locally is impractical). The imagetools merge the workflow uses is
# already proven by the real CI publish; here we just prove both arches build + assemble.
run_multiarch() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%smissing tool:%s docker  (start OrbStack / Docker Desktop)\n' "$red" "$rst"; exit 2
  fi
  need jq 'brew install jq'

  local builder='chrysalis-test-builder' tmpd oci log arches d idx_mt
  tmpd="$(mktemp -d)"
  oci="$tmpd/android-sdk.oci.tar"
  log="$tmpd/build.log"

  section 'buildx builder (docker-container)'
  if docker buildx inspect "$builder" >/dev/null 2>&1; then
    ok "reusing $builder"
  elif docker buildx create --name "$builder" --driver docker-container --bootstrap >/dev/null 2>&1; then
    ok "created $builder"
  else
    bad 'could not create a docker-container builder'; rm -rf "$tmpd"; return
  fi

  section 'amd64 emulation check'
  printf 'FROM alpine:3\nRUN echo ok\n' > "$tmpd/probe.Dockerfile"
  if docker buildx build --builder "$builder" --platform linux/amd64 \
       -f "$tmpd/probe.Dockerfile" --output type=cacheonly "$tmpd" >"$log" 2>&1; then
    ok 'amd64 builds run here'
  else
    skip 'amd64 emulation unavailable; enable it with:'
    printf '        docker run --privileged --rm tonistiigi/binfmt --install amd64\n'
    rm -rf "$tmpd"; return
  fi

  section 'build android-sdk for amd64 + arm64 (amd64 emulated, slow)'
  if docker buildx build --builder "$builder" --platform linux/amd64,linux/arm64 --provenance=false \
       -f sdk/Dockerfile.android --output "type=oci,dest=$oci" . >"$log" 2>&1; then
    ok 'built both arches'
  else
    bad 'android-sdk multi-arch build'; tail -n 30 "$log"; rm -rf "$tmpd"; return
  fi

  section 'manifest carries both arches'
  idx_mt="$(tar -xOf "$oci" index.json | jq -r '.manifests[0].mediaType')"
  if printf '%s' "$idx_mt" | grep -q 'image.index'; then
    d="$(tar -xOf "$oci" index.json | jq -r '.manifests[0].digest' | sed 's/sha256://')"
    arches="$(tar -xOf "$oci" "blobs/sha256/$d" | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"')"
  else
    arches="$(tar -xOf "$oci" index.json | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"')"
  fi
  if printf '%s\n' "$arches" | grep -qx 'linux/amd64' && printf '%s\n' "$arches" | grep -qx 'linux/arm64'; then
    ok "manifest arches: $(printf '%s' "$arches" | tr '\n' ' ')"
  else
    bad "manifest missing an arch (got: $(printf '%s' "$arches" | tr '\n' ' '))"
  fi

  rm -rf "$tmpd"
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    lint)      run_lint ;;
    image)     run_image ;;
    multiarch) run_multiarch ;;
    all)       run_lint; run_image ;;
    *) printf 'usage: %s [lint|image|multiarch|all]\n' "$0"; exit 2 ;;
  esac

  echo
  if [ "$failures" -gt 0 ]; then
    printf '%s%d check(s) failed%s\n' "$red" "$failures" "$rst"
    exit 1
  fi
  printf '%sall checks passed%s\n' "$grn" "$rst"
}

main "$@"
