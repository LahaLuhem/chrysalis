# CODESTYLE.md — `chrysalis`

Code-style conventions for this repo, for humans and coding agents alike: Dockerfiles,
workflow YAML, Bash, and the single-source-of-truth rule for version pins. Project facts and
hard rules live in [AGENTS.md](AGENTS.md); design rationale lives in [APPENDIX.md](APPENDIX.md).

Two habits cut across everything:

- **Comments explain *why*, not *what*.** The hairier the layer, the more it earns a
  comment; push the long story into an [APPENDIX.md](APPENDIX.md) anchor and link it.
- **Lint before "done".** `scripts/test.sh lint` runs hadolint, actionlint, shellcheck, and
  a `versions.env` sanity check from the pinned Linterpol image. A change isn't done until
  it's clean.

## Dockerfiles

- Group layers with `# --- Section ---` banners (one `RUN` per logical stage, `&&`-chained)
  and a top-of-file comment naming them (see `images/android-sdk/Dockerfile`).
- Pin every upstream `FROM` as `tag@sha256:<digest>`: the tag is the readable version, the
  digest makes the build reproducible. The one exception is our own rolling base, `flutter`
  FROM `android-sdk:latest` (DL3007 is ignored for it on purpose).
- `USER root`; these are build/CI images, not services (DL3002 on purpose).
- `LABEL org.opencontainers.image.source` + `.description` near the top.
- `ENV` names are UPPERCASE and grouped with `\` continuation; `ARG` names are lowercase
  (`flutter_version`). Keep related vars in one block.
- Collapse apt into one layer ending in `rm -rf /var/lib/apt/lists/*`; use
  `--no-install-recommends` (the inherited JDK block omits it by design, DL3015).
- Guard arch-specific steps on `uname -m` (`aarch64` / `x86_64`) and say why in a comment
  (e.g. the emulator is x86-only). Never assume the build arch.
- Every `.hadolint.yaml` ignore is a deliberate, commented choice; don't blanket-mute, and
  comment any rule you add.

## Workflow YAML

- 2-space indent. Each workflow opens with a human `name:` and a header comment covering what
  it does and any non-obvious gating.
- Pin actions by **full commit SHA + a trailing `# vN` comment**
  (`actions/checkout@<sha> # v7`). The SHA is what runs; the comment is what humans and
  Renovate read. Never a bare `@v7` (`config:best-practices` enforces the SHA pin).
- Minimal `permissions:` per job: `contents: read`, plus `packages: write` only where it
  pushes.
- Feed shell from an `env:` block; don't interpolate `${{ ... }}` straight into `run:`. It
  keeps steps injection-safe and shellcheck-clean. Quote expansions, and set `shell: bash`
  when you use bashisms (arrays, `<<<`).
- Lead a `run: |` block with a `#` comment when the step isn't self-evident.
- Shared build logic is a `workflow_call` workflow with typed, `description:`'d inputs
  (`build-image.yml`); the caller threads `versions.env` into build args
  (`build_and_push.yml`).

## Bash

- `#!/usr/bin/env bash` and `set -euo pipefail`. Open with a comment block: what it does, its
  subcommands, a usage line.
- Resolve the repo root from `${BASH_SOURCE[0]}` and `cd` there so it runs from anywhere.
- `printf` over `echo` for anything interpolated; quote every expansion. Functions are
  lowercase snake_case with `local` vars.
- Factor repeated output into small named helpers (`section`/`ok`/`bad`/`skip`) and gate
  colour on a TTY (`[ -t 1 ]`) so CI logs stay plain.
- On a missing tool, fail with what's missing and how to get it, not a bare non-zero.
- Keep it shellcheck-clean. A genuine false positive (e.g. a `$VAR` meant for a container's
  shell, not this one) gets a one-line `# shellcheck disable=SCxxxx` with a why, never a
  blanket mute.

## Version pins (single source of truth)

A Renovate-managed version lives in exactly one place: the pin it manages. Don't copy that
number into prose, comments, `LABEL`s, the README, or tables; the copy goes stale on the next
bump and the two silently disagree.

- `FLUTTER_VERSION` and `DOCKER_TAG` live only in `versions.env`; the workflow `source`s it
  and passes `flutter_version` in as a build arg.
- The `ubuntu` base version belongs only in the digest-pinned `FROM` in
  `images/android-sdk/Dockerfile`. Everywhere else (comments, `LABEL`s, the README) write
  `ubuntu` with no version.
- Renovate owns the bumps (`.github/renovate.jsonc`). `config:best-practices` auto-tracks the
  `FROM` digests and action SHAs; a custom manager handles the rest (the Flutter pin, the
  Linterpol lint image), which each need a `# renovate: datasource=... depName=...` line
  directly above the pin.
- Exception: the Flutter DX CLIs (`cider`, `dependency_validator`) are pinned inline on the
  chained `dart pub global activate` RUN in `images/flutter/Dockerfile` and tracked by a
  `datasourceTemplate: dart` custom manager with no `# renovate:` marker (a marker between the
  consecutive `RUN`s would trip hadolint DL3059). To add another, append
  `&& dart pub global activate <pkg> <x.y.z>` to that RUN; the manager picks it up.
- Don't hand-edit a tracked pin (`versions.env`'s `FLUTTER_VERSION` included) unless the user
  asks; that's Renovate's job. Any pin you do touch, verify against the upstream registry,
  never from memory.

> **Why:** Renovate rewrites the pin it manages, never the free text around it. A 24.04 → 26.04
> base bump left the `FROM` correct while a `LABEL`, the README, and a doc comment still said
> 24.04. Keeping the number in one managed place keeps it authoritative.
