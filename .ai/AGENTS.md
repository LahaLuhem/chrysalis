# AGENTS.md — `chrysalis`

Tool-agnostic brief for any coding agent (Claude Code, Copilot, Cursor, Codex, …) working
in this repo. Claude-Code-specific guidance lives in [CLAUDE.md](./CLAUDE.md); design
rationale and rejected paths live in [`../APPENDIX.md`](../APPENDIX.md) (anchor-keyed).
Read this first.

## Project goal

`chrysalis` builds and publishes **multi-arch (`linux/amd64` + `linux/arm64`) Docker
images** bundling **Flutter + the Android SDK**, to **GHCR under `ghcr.io/lahaluhem`**,
tracking the **latest stable Flutter** release.

Two images:

- **`android-sdk:latest`** — Ubuntu + Android `cmdline-tools`, `platform-tools`,
  `build-tools`, a platform. The base layer.
- **`flutter:<version>` / `flutter:stable`** — `FROM` the `android-sdk` image, clones
  Flutter at the pinned version.

It is a fork of [`davidmartos96/docker-images-flutter`](https://github.com/davidmartos96/docker-images-flutter),
itself a fork of the now-EOL
[`cirruslabs/docker-images-flutter`](https://github.com/cirruslabs/docker-images-flutter).
Why it exists: [`APPENDIX.md#why-multi-arch`](../APPENDIX.md#why-multi-arch).

## Scope — what this repo is and is NOT

- **In scope:** building and publishing good OCI images — the Dockerfiles, the
  build/publish workflow, and version tracking.
- **Out of scope (by design):** *how or where* the images are consumed. These are standard
  OCI images — any CI system, any OCI runtime. Consumption is portable and decided
  separately. **Do not add consumer-specific logic** (no CI-system-specific entrypoints, no
  runtime assumptions).

## Stack

- **Docker Buildx** — multi-platform builds. The publish path uses a native runner matrix +
  push-by-digest + `docker buildx imagetools create` manifest merge
  ([`APPENDIX.md#digest-merge-multiarch`](../APPENDIX.md#digest-merge-multiarch)).
- **GitHub Actions** — `.github/workflows/`. Hosted runners: `ubuntu-latest` (amd64) +
  `ubuntu-24.04-arm` (arm64; free for public repos). GitHub macOS runners are arm64
  **macOS** and cannot build Linux arm64 images — never use them for that.
- **GHCR** — `ghcr.io/lahaluhem` (lowercase; GHCR namespaces are lowercase).
- **Renovate** — version tracking. `config:best-practices` (Mend-hosted) bumps the Flutter SDK
  pin (custom manager + `flutter-version` datasource), the GitHub Actions pins, the `ubuntu`
  base, and the CI lint tools hadolint + actionlint (custom manager + `github-releases`); opens
  PRs weekly. Config: `.github/renovate.json`.
- **Bash** — `scripts/test.sh` (local test suite).
- Pinned inputs live in **`versions.env`** (`DOCKER_TAG`, `FLUTTER_VERSION`).

## Repo layout

```
chrysalis/
├── versions.env                     DOCKER_TAG=stable, FLUTTER_VERSION=<x.y.z> (pinned inputs)
├── images/
│   ├── android-sdk/                 ubuntu:24.04 + Android cmdline/platform/build tools
│   │   ├── Dockerfile               (arm64-aware: skips `sdkmanager emulator` on arm64)
│   │   ├── structure-test.yaml      container-structure-test assertions
│   │   └── .dockerignore
│   └── flutter/                     FROM android-sdk; clones Flutter at FLUTTER_VERSION
│       ├── Dockerfile
│       ├── structure-test.yaml
│       └── .dockerignore
├── scripts/
│   └── test.sh                      Local test suite (lint / image / multiarch / all)
├── .github/
│   ├── workflows/                   build_and_push.yml (build+publish), build-image.yml (reusable), test.yml (lint)
│   └── renovate.json                Renovate: version tracking (Flutter pin, Actions, ubuntu base)
├── .hadolint.yaml                   hadolint rules (deliberate ignores)
├── README.md                        Image names, what's inside, usage
├── APPENDIX.md                      Design rationale (anchor-keyed)
└── .ai/                             This file + CLAUDE.md (symlinked at root, gitignored)
```

## Hard rules

1. **Scope is build + publish only.** Don't add anything about *consuming* the images (see
   *Scope*). Consumption is intentionally portable and out of scope.
2. **Registry is `ghcr.io/lahaluhem`** (lowercase). The package names — `flutter`,
   `android-sdk` — stay as-is.
3. **`android-sdk` is the base for `flutter`.** Its multi-arch manifest list must be
   **published before** the `flutter` matrix builds, so each per-arch `flutter` build
   resolves the matching base. Workflow order: build-android → merge-android → build-flutter
   → merge-flutter.
4. **Multi-arch is built natively, not via QEMU.** Matrix: amd64 on `ubuntu-latest`, arm64
   on `ubuntu-24.04-arm`. The single-job QEMU `platforms: linux/amd64,linux/arm64` approach
   is the documented *fallback* only. macOS runners cannot build Linux arm64.
5. **arm64 cannot build Android apps natively.** Google ships the Android *Linux* build
   tools (`aapt2`, `cmake`, `ninja`, NDK, `adb`) as **x86-64-only**; `flutter build apk`
   fails on native arm64 without x86 emulation. Native arm64 is fine for
   `flutter`/`dart`/test/analyze. **Never claim arm64 builds Android natively.** Evidence +
   implications: [`APPENDIX.md#arm64-android-build-limitation`](../APPENDIX.md#arm64-android-build-limitation).
6. **Publishing is gated** to `master` pushes and manual `workflow_dispatch`. Pull requests
   build-validate without pushing. Rationale (shared-tag races):
   [`APPENDIX.md#publish-gating`](../APPENDIX.md#publish-gating).
7. **Verify action/tool versions against their registries before pinning** — never from
   memory (GitHub API `releases/latest`, Docker Hub, pub.dev). See
   `~/.claude/rules/dependency-versions.md`.
8. **Never report a multi-arch publish as successful without `docker manifest inspect
   <ref>` showing BOTH `linux/amd64` and `linux/arm64`.**
9. **Keep version tracking arch-independent.** Renovate (`.github/renovate.json`) watches the
   stable Flutter channel and opens a weekly version-bump PR; merging republishes. Version
   tracking stays platform-agnostic by design; never couple it to an arch.

## Build & publish flow

1. `versions.env` pins `FLUTTER_VERSION` (and `DOCKER_TAG=stable`).
2. On `master` / `workflow_dispatch`, `build_and_push.yml`:
   - builds `android-sdk` for each arch (native runner), pushes by digest, merges into
     `android-sdk:latest`;
   - builds `flutter` for each arch `FROM` that manifest list, pushes by digest, merges into
     `flutter:<version>` + `flutter:stable`.
3. Weekly, Renovate (`.github/renovate.json`) checks the stable Flutter channel; if it moved, it
   opens a PR bumping `versions.env`. Merging triggers a republish.

## Testing

`scripts/test.sh` runs the suite locally, no CI round-trip needed:

- `scripts/test.sh lint` runs hadolint, actionlint, shellcheck, and a `versions.env` check.
- `scripts/test.sh image` builds `android-sdk` + `flutter` for the host arch and asserts
  their contents with [container-structure-test](https://github.com/GoogleContainerTools/container-structure-test)
  (specs in `images/<name>/structure-test.yaml`), plus a version match and the arm64 emulator invariant.
- `scripts/test.sh multiarch` builds `android-sdk` for amd64 + arm64 (amd64 emulated) and
  asserts the resulting manifest carries both arches. Slow and opt-in, not part of `all`.
- `scripts/test.sh all` runs lint + image.

Run it before touching the Dockerfiles or the workflow. Tools install via `brew`
(hadolint, actionlint, shellcheck, container-structure-test); on this OrbStack host the
script points container-structure-test at the right Docker socket automatically.

## Code style (no separate CODESTYLE.md yet)

The code surface is small; until a `CODESTYLE.md` is warranted, follow:

- **Dockerfiles:** one `RUN` per logical stage, chained with `&&`; clean apt lists in the
  same layer (`rm -rf /var/lib/apt/lists/*`). Keep arch guards explicit
  (`if [ "$(uname -m)" = "x86_64" ]; then …; fi`).
- **Workflow YAML:** 2-space indent; pin actions to a major tag (`@v7`); keep `run:` blocks
  `actionlint`/shellcheck-clean, marking intentional word-splitting with
  `# shellcheck disable=SCxxxx`.
- **Bash:** `set -e`; quote expansions; use only POSIX `sh` features where the shebang is
  `#!/bin/sh`.
