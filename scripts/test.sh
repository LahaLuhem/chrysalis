#!/usr/bin/env bash
#
# Local test suite for chrysalis (a Docker image build/publish repo).
#
#   lint    Static checks, no Docker: hadolint, actionlint, shellcheck, versions.env.
#   image   Build the images and assert their contents (added in the image-tests layer).
#   all     Everything.
#
# Usage: scripts/test.sh [lint|image|all]   (default: all)
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

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  printf '%smissing tool:%s %s  (install: %s)\n' "$red" "$rst" "$1" "$2"
  exit 2
}

check_versions_env() {
  local f='versions.env' tag ver
  if [ ! -f "$f" ]; then bad "$f is missing"; return; fi
  tag="$(grep -E '^DOCKER_TAG=' "$f" | cut -d= -f2- || true)"
  ver="$(grep -E '^FLUTTER_VERSION=' "$f" | cut -d= -f2- || true)"
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

run_image() {
  printf '%simage tests land in the next layer (Layer 2: container-structure-test)%s\n' "$ylw" "$rst"
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    lint)  run_lint ;;
    image) run_image ;;
    all)   run_lint; run_image ;;
    *) printf 'usage: %s [lint|image|all]\n' "$0"; exit 2 ;;
  esac

  echo
  if [ "$failures" -gt 0 ]; then
    printf '%s%d check(s) failed%s\n' "$red" "$failures" "$rst"
    exit 1
  fi
  printf '%sall checks passed%s\n' "$grn" "$rst"
}

main "$@"
