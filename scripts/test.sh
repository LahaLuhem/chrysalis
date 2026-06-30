#!/usr/bin/env bash
#
# Local test suite for chrysalis (a Docker image build/publish repo).
#
#   lint       Static checks: hadolint, actionlint, shellcheck, biome, versions.env. The linters
#              run from the linterpol image, pulled on demand (override LINTERPOL_IMAGE).
#   image      Build android-sdk + flutter for the host arch and assert their contents
#              with container-structure-test, plus a version-match and arch invariant.
#   apk        Build a debug APK from a throwaway app in the flutter image, proving the
#              Android toolchain works end to end (arm64 runs it under x86 emulation).
#              Slow; opt-in, not part of `all`.
#   multiarch  Build android-sdk for amd64 + arm64 (amd64 emulated) and assert the
#              resulting manifest carries both arches. Slow; opt-in, not part of `all`.
#   all        lint + image.
#
# Usage: scripts/test.sh [lint|image|apk|multiarch|all]   (default: all)
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

# The lint tools (hadolint, actionlint, shellcheck, biome) run from the linterpol image, so they
# don't have to be installed on the host and every run (local or CI) uses the same pinned
# versions. The repo is mounted read-only at /work, so the repo-relative paths callers pass
# resolve there. Override the image with LINTERPOL_IMAGE (e.g. a locally-built linterpol:local
# when developing Linterpol itself). Pinned by digest; Renovate bumps it (.github/renovate.jsonc).
# renovate: datasource=docker depName=ghcr.io/lahaluhem/linterpol
LINTERPOL_IMAGE="${LINTERPOL_IMAGE:-ghcr.io/lahaluhem/linterpol:latest@sha256:0c7b9fd505693f47346e1218d58ae87a2ee19c38dc56e0f7333af7914b63e9b3}"
linterpol_ready=''

# Make sure LINTERPOL_IMAGE is present locally, pulling it on demand (the default is a public ghcr ref).
# A local-only tag that hasn't been built will fail the pull, with a hint.
ensure_linterpol_image() {
  [ -n "$linterpol_ready" ] && return 0
  if docker image inspect "$LINTERPOL_IMAGE" >/dev/null 2>&1; then
    linterpol_ready=1
    return 0
  fi
  printf 'pulling %s\n' "$LINTERPOL_IMAGE"
  if docker pull "$LINTERPOL_IMAGE" >/dev/null 2>&1; then
    linterpol_ready=1
    return 0
  fi
  printf '%scould not pull%s %s\n' "$red" "$rst" "$LINTERPOL_IMAGE"
  printf '       check the ref, or set LINTERPOL_IMAGE to a tag you have built (linterpol repo: ./scripts/build.sh)\n'
  exit 2
}

# lint_tool <tool> <args...>: run a linter from the linterpol image (the host isn't assumed
# to have the tools; the image is the single source of versions).
lint_tool() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%smissing tool:%s docker is required to run the linters from the linterpol image\n' "$red" "$rst"
    exit 2
  fi
  ensure_linterpol_image
  docker run --rm -v "$repo_root:/work:ro" -w /work "$LINTERPOL_IMAGE" "$@"
}

# structure_test <image-under-test> <config>: run container-structure-test from the linterpol
# image. The image-under-test lives in the host Docker daemon (built by run_image), so the
# host's Docker socket is mounted in (Docker-out-of-Docker) and the container runs as root to
# reach it. The specs use commandTests, which need the daemon driver (the tar driver can't
# execute commands).
structure_test() {
  ensure_linterpol_image
  local sock
  sock="$(docker context inspect -f '{{.Endpoints.docker.Host}}' 2>/dev/null | sed 's|^unix://||' || true)"
  [ -n "$sock" ] || sock='/var/run/docker.sock'
  docker run --rm --user 0:0 \
    -v "$sock:/var/run/docker.sock" \
    -v "$repo_root:/work:ro" -w /work \
    "$LINTERPOL_IMAGE" \
    container-structure-test test --image "$1" --config "$2"
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
  section 'hadolint (Dockerfiles)'
  if lint_tool hadolint images/android-sdk/Dockerfile images/flutter/Dockerfile; then ok 'Dockerfiles clean'; else bad 'hadolint'; fi

  section 'actionlint (workflows)'
  if lint_tool actionlint .github/workflows/*.yml; then ok 'workflows clean'; else bad 'actionlint'; fi

  section 'shellcheck (shell scripts)'
  if lint_tool shellcheck scripts/*.sh; then ok 'scripts clean'; else bad 'shellcheck'; fi

  section 'biome (JSON/JSONC)'
  if lint_tool biome lint .; then ok 'JSON/JSONC clean'; else bad 'biome'; fi

  section 'versions.env sanity'
  check_versions_env
}

# Host-arch image tags (CI covers both arches via the matrix).
img_android='chrysalis-test/android-sdk:local'
img_flutter='chrysalis-test/flutter:local'

# build_host_images: build android-sdk + flutter for the host arch into the tags above.
build_host_images() {
  local ver base log
  ver="$(flutter_version)"
  base='ghcr.io/lahaluhem/android-sdk:latest'
  log="$(mktemp)"

  section 'build android-sdk (host arch)'
  if docker buildx build --load -t "$img_android" images/android-sdk >"$log" 2>&1; then
    ok 'built android-sdk'
  else
    bad 'android-sdk build'; tail -n 30 "$log"; rm -f "$log"; return 1
  fi

  section 'build flutter (host arch)'
  if docker buildx build --load \
       --build-context "$base=docker-image://$img_android" \
       --build-arg "flutter_version=$ver" \
       -t "$img_flutter" images/flutter >"$log" 2>&1; then
    ok 'built flutter'
  else
    bad 'flutter build'; tail -n 30 "$log"; rm -f "$log"; return 1
  fi
  rm -f "$log"
}

run_image() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%smissing tool:%s docker  (start OrbStack / Docker Desktop)\n' "$red" "$rst"; exit 2
  fi

  build_host_images || return

  local ver arch android_img flutter_img
  ver="$(flutter_version)"
  arch="$(uname -m)"
  android_img="$img_android"
  flutter_img="$img_flutter"

  section 'container-structure-test: android-sdk'
  if structure_test "$android_img" images/android-sdk/structure-test.yaml; then
    ok 'android-sdk structure'
  else
    bad 'android-sdk structure'
  fi

  section 'container-structure-test: flutter'
  if structure_test "$flutter_img" images/flutter/structure-test.yaml; then
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

  # The Android emulator is x86_64-only; images/android-sdk/Dockerfile skips it on arm64.
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

  # arm64 runs the (x86-64) Android tools only under host emulation; the image bakes the
  # x86-64 libs they load (asserted in structure-test.yaml). Here, prove aapt2 actually
  # runs. That needs host x86-64 emulation (Apple Silicon Docker/OrbStack: built-in; bare
  # arm64 Linux: `docker run --privileged --rm tonistiigi/binfmt --install amd64`), so a
  # non-runnable aapt2 is a SKIP, not a failure.
  if [ "$arch" = "arm64" ] || [ "$arch" = "aarch64" ]; then
    section 'arm64 Android tools run under x86-64 emulation'
    # $-expansions run in the container shell, not here.
    # shellcheck disable=SC2016
    if docker run --rm "$android_img" sh -c 'aapt2="$(ls "$ANDROID_HOME"/build-tools/*/aapt2 | head -1)"; exec "$aapt2" version' >/dev/null 2>&1; then
      ok 'aapt2 runs (x86-64 emulation available)'
    else
      skip 'aapt2 not runnable here; register emulation: docker run --privileged --rm tonistiigi/binfmt --install amd64'
    fi
  fi
}

# Builds a debug APK from a throwaway app in the flutter image, proving the Android
# toolchain works end to end (on arm64 the SDK build tools run under x86 emulation).
# Slow; opt-in, not part of `all`.
run_apk() {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%smissing tool:%s docker  (start OrbStack / Docker Desktop)\n' "$red" "$rst"; exit 2
  fi

  build_host_images || return

  section 'flutter build apk --debug (throwaway app)'
  # The $-expansions below run in the container's shell, not here, hence single quotes.
  # shellcheck disable=SC2016
  if docker run --rm "$img_flutter" bash -c '
        set -euo pipefail
        app="$(mktemp -d)/smoke"
        flutter create "$app" >/dev/null
        cd "$app"
        flutter build apk --debug
        find build -name "*.apk" | grep -q .'; then
    ok 'built a debug APK'
  else
    bad 'flutter build apk --debug'
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
       --output "type=oci,dest=$oci" images/android-sdk >"$log" 2>&1; then
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
    apk)       run_apk ;;
    multiarch) run_multiarch ;;
    all)       run_lint; run_image ;;
    *) printf 'usage: %s [lint|image|apk|multiarch|all]\n' "$0"; exit 2 ;;
  esac

  echo
  if [ "$failures" -gt 0 ]; then
    printf '%s%d check(s) failed%s\n' "$red" "$failures" "$rst"
    exit 1
  fi
  printf '%sall checks passed%s\n' "$grn" "$rst"
}

main "$@"
