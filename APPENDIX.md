<!-- TOC start -->

- [`AGENTS.md` and `CLAUDE.md` are symlinks into `.ai/`](#ai-files-symlinked)
- [Why this fork exists: maintained *and* multi-arch](#why-multi-arch)
- [arm64 Linux cannot build Android apps (the x86-64 toolchain wall)](#arm64-android-build-limitation)
- [Multi-arch via native matrix + push-by-digest + manifest merge](#digest-merge-multiarch)
- [Publishing is gated to `master` and manual dispatch](#publish-gating)

<!-- TOC end -->

Consolidated source of truth for design decisions, rejected paths, and non-obvious
trade-offs. The README, [`.ai/AGENTS.md`](./.ai/AGENTS.md), and
[`.ai/CLAUDE.md`](./.ai/CLAUDE.md) reference sections here by anchor (e.g.
`APPENDIX.md#arm64-android-build-limitation`).

---

<a id="ai-files-symlinked"></a>
## `AGENTS.md` and `CLAUDE.md` are symlinks into `.ai/`

- **Decision:** the canonical text for both files lives under `.ai/`. The repo root holds
  symlinks (`AGENTS.md → .ai/AGENTS.md`, `CLAUDE.md → .ai/CLAUDE.md`). A sub-scope guide
  would follow the same pattern (`<subdir>/AGENTS.md → <subdir>/.ai/AGENTS.md`) if one is
  ever added.
- **Why:** Claude Code (and most coding agents) auto-discover `CLAUDE.md` / `AGENTS.md` at
  the project root, but two more loose Markdown files at the root add visual noise. Scoping
  the agent-guidance files under `.ai/` keeps them together; the root symlinks preserve
  auto-discovery.
- **Committed vs. local:** the `.ai/` canonical files are committed; the root symlinks are
  **gitignored** (`/AGENTS.md`, `/CLAUDE.md` in [`.gitignore`](./.gitignore)), so nothing in
  the build pipeline depends on them. Each contributor (or their agent) recreates the
  symlinks locally:

  ```bash
  ln -s .ai/AGENTS.md AGENTS.md
  ln -s .ai/CLAUDE.md CLAUDE.md
  ```

  A **real file** at the root beats the symlink — if a contributor prefers a committed root
  `AGENTS.md`/`CLAUDE.md`, that works too; the `.ai/` copies stay the default.
- **Cross-platform note:** symlinks survive `git clone` on macOS/Linux. On Windows hosts
  without symlink support the file shows up as a small text file containing the link target;
  the fallback is real files at root, hand-synced.
- **No `CODESTYLE.md` yet:** the code surface (Dockerfiles, workflow YAML, one shell script)
  is small, so style is folded into [`.ai/AGENTS.md`](./.ai/AGENTS.md) rather than split into
  a speculative `CODESTYLE.md`. When it grows, `CODESTYLE.md` goes at the root (not
  symlinked — style serves humans and agents alike).

---

<a id="why-multi-arch"></a>
## Why this fork exists: maintained *and* multi-arch

- **`cirruslabs/docker-images-flutter` was multi-arch but is EOL.** Cirrus Labs is joining
  OpenAI; the images froze ~2026-05-01. They shipped genuine `linux/amd64` + `linux/arm64`
  manifests (verified via `docker buildx imagetools inspect`), but receive no further
  updates.
- **The `davidmartos96` fork tracks the latest Flutter but is amd64-only.** Its workflow
  hardcodes `platforms: linux/amd64` and the QEMU setup step is commented out.
- **`chrysalis` wants both:** the latest stable Flutter *and* native `arm64`, maintained
  under our own GHCR namespace (`ghcr.io/lahaluhem`). "Native arm64" has a sharp caveat for
  Android builds — see [#arm64-android-build-limitation](#arm64-android-build-limitation).

---

<a id="arm64-android-build-limitation"></a>
## arm64 Linux cannot build Android apps (the x86-64 toolchain wall)

**Verified empirically** on a native arm64 host (Apple Silicon + OrbStack, no QEMU/binfmt):
a *native* arm64 Linux image **cannot build Android apps**.

- **Google ships the Linux Android SDK tools as x86-64 only.** In the arm64 image,
  `aapt2`, `aapt`, `zipalign`, `dexdump`, `adb`, `fastboot`, `cmake`, `ninja`, and the NDK
  toolchain are all x86-64 ELF binaries. There are no arm64 Linux variants in Google's SDK
  repository. Even the Android Gradle Plugin, *running on arm64*, downloads the `-linux`
  (x86-64) maven `aapt2` because no `linux-arm64` classifier exists.
- **`flutter build apk --debug` fails on native arm64** at
  `:app:configureCMakeDebug[arm64-v8a]` with
  `Dynamic loader not found: /lib64/ld-linux-x86-64.so.2` — i.e. an x86 program on an arm64
  OS with no emulation.
- **What *does* run native arm64:** `flutter`, `dart`, `java` (aarch64), and the JVM-wrapper
  tools (`d8`, `apksigner`). So the arm64 image is genuinely useful for
  `flutter test`/`analyze`/`pub` and web builds, but **Android builds require x86 emulation**
  (host `binfmt`/QEMU), which is slow and defeats "native = fast".
- **cirruslabs had the same limitation.** Their Dockerfiles do nothing arm64-specific, and
  their CI only smoke-tested the **x86_64** emulator path — so the published arm64 Android
  build was never actually verified. A present manifest is not a verified build.
- **Implication / open decision:** the arm64 strategy is a product choice — ship multi-arch
  and document the caveat; bundle `qemu-user-static`; or stay amd64-only. (Decision pending
  with the user as of writing.) Whatever is chosen, **do not document or claim that arm64
  builds Android apps natively.**

---

<a id="digest-merge-multiarch"></a>
## Multi-arch via native matrix + push-by-digest + manifest merge

- **Native matrix over QEMU.** amd64 builds on `ubuntu-latest`, arm64 on `ubuntu-24.04-arm`
  (a free hosted runner for public repos). Native arm64 is far faster than emulating arm64
  on an amd64 host, and avoids QEMU flakiness. The single-job QEMU approach
  (`platforms: linux/amd64,linux/arm64`) is kept in mind only as a fallback.
- **Push-by-digest + `imagetools create`.** Each matrix leg builds and pushes its image *by
  digest* (`outputs: type=image,...,push-by-digest=true`), uploads the digest as an
  artifact, and a merge job assembles the per-arch digests into one manifest list with
  `docker buildx imagetools create`. This is the canonical Docker pattern for distributing a
  multi-platform build across native runners.
- **`android-sdk` is published before `flutter` builds.** Because `images/flutter/Dockerfile` is
  `FROM ghcr.io/lahaluhem/android-sdk:latest`, that tag must already be a manifest list when
  the `flutter` matrix runs, so each per-arch `flutter` build pulls the matching base
  automatically. Hence the job order build-android → merge-android → build-flutter →
  merge-flutter.
- **`provenance: false`.** Provenance/SBOM attestations add `unknown/unknown` entries to the
  manifest list that muddy `docker manifest inspect`; disabling them keeps the manifest to
  exactly the two platform images.

---

<a id="publish-gating"></a>
## Publishing is gated to `master` and manual dispatch

- **Publish on `master` pushes and `workflow_dispatch`; pull requests build-validate without
  pushing.** This keeps the shared tags (`android-sdk:latest`, `flutter:stable`,
  `flutter:<version>`) from being clobbered by every branch, while still validating both
  arches on PRs and giving a deliberate manual path to publish/verify a branch
  (`gh workflow run build_and_push.yml --ref <branch>`).
- **Why not push on every branch:** concurrent branch builds would race on the same tags.
  Gating to `master` + explicit dispatch makes publishing intentional.
- **Verification:** a publish is only "done" once `docker manifest inspect <ref>` shows both
  `linux/amd64` and `linux/arm64`. Never report success without it.
