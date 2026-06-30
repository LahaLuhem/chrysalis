<!-- TOC start -->

- [`AGENTS.md` and `CLAUDE.md` are symlinks into `.ai/`](#ai-files-symlinked)
- [Why this fork exists: maintained *and* multi-arch](#why-multi-arch)
- [arm64 Linux builds Android only under x86-64 emulation](#arm64-android-build-limitation)
- [Flutter is installed by `git clone`, not the release tarball](#flutter-clone-not-tarball)
- [Multi-arch via native matrix + push-by-digest + manifest merge](#digest-merge-multiarch)
- [Publishing is gated to `master` and manual dispatch](#publish-gating)
- [Version tracking via Renovate, not a bespoke cron](#renovate-version-tracking)
- [Quiet-by-default: telemetry off, version check skipped](#quiet-ci-defaults)

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
## arm64 Linux builds Android only under x86-64 emulation

**Decision (resolved):** ship multi-arch and make the arm64 image *able* to build Android by
baking in the x86-64 runtime libs its (x86-64) Android tools need, so builds work on any host
that can emulate x86-64. Validated on Apple Silicon + OrbStack with a real
`flutter build apk --debug` that produced an APK. It is **emulated, never native**; do not
claim otherwise.

### The wall
Google ships the Linux Android SDK tools (`aapt2`, `aapt`, `zipalign`, `dexdump`, `adb`,
`cmake`, `ninja`, the NDK) as **x86-64 only**; there are no arm64 Linux variants, and the
Android Gradle Plugin on arm64 still fetches the `-linux` (x86-64) maven `aapt2`. On a bare
arm64 host `flutter build apk` reaches `:app:configureCMakeDebug[arm64-v8a]` and dies with
`Dynamic loader not found: /lib64/ld-linux-x86-64.so.2`.

### What actually makes it work: two ingredients
That loader error is the tell. It takes **both**:

1. **Host x86-64 emulation.** Verified: an x86-64 *static* binary runs inside an arm64
   container on OrbStack with no setup. The emulation is the host's to provide.
2. **x86-64 userland libs in the image.** A *dynamic* x86-64 binary still fails until the
   image carries the x86-64 loader and libs. `readelf` on the real tools pins the exact set:
   - `aapt2` needs `libc6` + `libgcc-s1`.
   - NDK `clang` needs `libc6` + `libgcc-s1` + **`zlib1g`** (`libz.so.1`); even the default
     app triggers an NDK CMake configure, so this is not optional.
   - `cmake` statically links its C++ runtime (needs `libc6` only); `aapt`/`zipalign` use the
     `libc++.so` bundled in `build-tools/lib64`; **nothing links `libstdc++.so.6`**.

   So the minimal baked set is **`libc6` + `libgcc-s1` + `zlib1g`** (the arm64-guarded
   emulation-libs layer in `images/android-sdk/Dockerfile`). amd64 is untouched.

### Host support matrix
| Host | x86-64 emulation | Setup |
| --- | --- | --- |
| Apple Silicon + OrbStack | built-in | none |
| Apple Silicon + Docker Desktop | yes | enable "Use Rosetta…", else QEMU |
| arm64 Linux (Graviton, Pi, CI) | only if registered | `docker run --privileged --rm tonistiigi/binfmt --install amd64` |
| arm64 Linux, nothing registered | none | builds still can't run the tools |

### Performance
Most of an Android build is JVM work (Gradle, AGP, `d8`/`r8`) that runs **native arm64**.
Only the native tools (`aapt2`, `zipalign`, and `cmake`/`ninja`/clang for NDK steps) are
emulated, so overhead scales with how much native code you build: mild on Apple Silicon
(Rosetta-class), heavier on QEMU hosts.

### Rejected paths
- **Document-only (consumer installs the libs).** Clunky; pushes a setup chore onto every
  user when a tiny image layer removes it.
- **Bundle `qemu-user-static` + per-tool wrapper scripts.** Self-contained on any arm64
  Linux, but fragile and high-maintenance (every native tool wrapped; AGP/NDK bumps add
  more). The host-emulation requirement is the honest, low-maintenance floor instead.
- **A separate lean vs build-capable image.** The strict lib set is three packages, so the
  split would double the build matrix, tags, and maintenance to save almost nothing. Revisit
  only if a heavy x86-64 NDK is ever bundled (which isn't in scope for amd64 either).
- **An iOS/macOS `flutter-mac` image.** Out of scope, and not a Docker image at all: iOS
  needs a **macOS VM on Apple Silicon Mac hardware** (Tart / Apple `Virtualization.framework`),
  a separate Mac-only product. Do iOS on macOS CI runners; a Tart image, if ever wanted, is a
  separate sibling repo.

### Guards
`images/android-sdk/structure-test.yaml` asserts the x86-64 loader is present (deterministic,
runs on both arches in CI). `scripts/test.sh` (`image` target) additionally runs `aapt2` under
emulation on arm64, skipping rather than failing where the host has no emulation registered.

### Prior art
cirruslabs shipped arm64 manifests with the same x86-64-tool reality but only ever
smoke-tested the x86_64 emulator path, so their arm64 Android build was never actually
verified. A present manifest is not a verified build.

---

<a id="flutter-clone-not-tarball"></a>
## Flutter is installed by `git clone`, not the release tarball

- **Decision:** the `flutter` image gets its SDK from
  `git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git`
  ([`images/flutter/Dockerfile`](./images/flutter/Dockerfile)), not from the prebuilt
  `flutter_linux_<ver>-stable.tar.xz` release archive the
  [manual-install docs](https://docs.flutter.dev/install/manual) point at.
- **Why (the decisive reason): there is no arm64 Linux Flutter tarball.** Every stable entry in
  Flutter's `releases_linux.json` is `dart_sdk_arch: x64` (zero arm64). That archive bundles an
  **x64 Dart SDK**, so dropping it onto the arm64 image would run `flutter`/`dart` under x86-64
  emulation. That breaks the native-arm64 promise this fork exists for
  ([#why-multi-arch](#why-multi-arch)) and contradicts AGENTS hard rule 5 ("native arm64 is fine
  for `flutter`/`dart`/test/analyze").
- **What the clone does instead:** it fetches only the framework and tooling (arch-independent
  Dart source plus shell scripts); the first `flutter` run bootstraps the **host-arch** Dart SDK
  via `bin/internal/update_dart_sdk.sh`. So each per-arch image gets an arch-matched native Dart
  with no extra logic:
  - Flutter SDK tarball (`releases_linux.json`): x64 only, no arm64 published.
  - Dart SDK (`dart-archive`): both arches, including `dartsdk-linux-arm64-release.zip` (what the
    bootstrap pulls on the arm64 build).
- **Why "involving git" is not actually heavy-handed:**
  - **git is a hard Flutter dependency regardless of install method.** flutter_tools shells out to
    git for version/channel/upgrade detection, and Flutter's manual-install page lists Git as a
    required prerequisite *for the tarball route too*, so it is in the image either way.
  - `--depth 1 --branch <tag>` is a shallow, single-branch checkout, not full history.
  - The heavy bytes (Android engine artifacts) are pulled by `flutter precache --android` on first
    run under either method, so the clone's only extra cost is a small shallow `.git`.
- **Ties into version tracking:** the pin is consumed as the clone's `--branch` tag and tracked by
  Renovate's `flutter-version` datasource; see
  [#renovate-version-tracking](#renovate-version-tracking) for why that beats Dependabot.
- **Rejected: download the x64 tarball and hand-swap an arm64 Dart SDK.** Unsupported, and the
  tarball's framework expects its bundled Dart; the clone's bootstrap is the maintained path that
  resolves the correct Dart per arch.

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

<a id="oci-native-images"></a>
## OCI-native images

- **Decision:** the published images are OCI-native. Each per-arch push-by-digest build runs with
  `oci-mediatypes=true` (`outputs: type=image,...,oci-mediatypes=true` in `build-image.yml`), so the
  arch's manifest, config, and layers carry `vnd.oci.*` media types instead of Docker schema 2;
  `docker buildx imagetools create` then assembles them into an
  `application/vnd.oci.image.index.v1+json` index. So `docker buildx imagetools inspect
  ghcr.io/lahaluhem/<img>:<tag> --raw` reports the OCI index type.
- **Metadata is workflow-owned, not baked into the Dockerfiles.** `docker/metadata-action` generates
  the OCI labels (image config) and annotations; the Dockerfiles carry no `LABEL`s. The split build
  means metadata attaches in two places: the per-arch push applies labels + manifest-level annotations
  (`DOCKER_METADATA_ANNOTATIONS_LEVELS: manifest`), and the merge applies index-level annotations, fed
  to `imagetools create --annotation "index:..."` (`...LEVELS: index`). `title`/`description` are
  curated per image (from `build_and_push.yml`); `source`/`revision`/`created`/`version`/`licenses`
  fill in from the repo and the build commit.
- **Two checks keep it honest.** On publish, the merge job runs
  [`scripts/assert_oci_registry.sh`](./scripts/assert_oci_registry.sh) (the index, both arches, and
  every manifest, config, and layer) plus `crane validate` on the pushed image. At PR time the amd64
  build leg runs [`scripts/assert_oci_layout.sh`](./scripts/assert_oci_layout.sh) against a `type=oci`
  build, so a regression to Docker media types fails before it can publish.
- **Why not bake `LABEL`s in the Dockerfile?** One source avoids drift (a label edited in one
  Dockerfile but not the other), lets `metadata-action` fill commit-derived fields
  (`revision`/`created`) a static `LABEL` can't, and covers index-level annotations, which aren't
  expressible as a Dockerfile `LABEL` at all (they live on the manifest list, which exists only after
  the merge).

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

---

<a id="renovate-version-tracking"></a>
## Version tracking via Renovate, not a bespoke cron

- **Decision:** one dedicated manager (Renovate, `config:best-practices`, Mend-hosted) owns
  every version bump, replacing the hand-rolled `update_flutter_versions.sh` +
  `check_flutter_versions.yml` cron. Config lives in
  [`.github/renovate.jsonc`](./.github/renovate.jsonc).
- **Why:** one tool beats scattered glue (a script here, a cron there). Less bespoke code to
  maintain, and Renovate opens, labels, and throttles the PRs itself. `config:best-practices`
  additionally SHA-pins the GitHub Actions and digest-pins the `ubuntu` base, which the old cron
  never did. Given the current wave of CI supply-chain attacks, pinning to immutable digests is
  worth the extra PR noise.
- **Why not Dependabot:** Dependabot only updates dependencies inside manifests of ecosystems it
  understands. The Flutter SDK pin is a bare string in `versions.env`, resolved from Flutter's
  releases JSON and consumed as a `git clone --branch` tag. No Dependabot ecosystem parses that,
  and it has no regex/custom-manager escape hatch. Renovate's custom manager plus the
  `flutter-version` datasource do exactly this.
- **How the Flutter pin is tracked:** a `customManagers` regex binds the
  `# renovate: datasource=flutter-version depName=flutter` marker above `FLUTTER_VERSION` in
  `versions.env`. The `flutter-version` datasource marks only the `stable` channel as stable, so
  with Renovate's default `ignoreUnstable` the pin only ever moves to a stable release, never a
  `.pre` beta. The `versions.env` lint in `scripts/test.sh` is a backstop that rejects any
  non-`x.y.z` value.
- **One exclusion:** `docker:pinDigests` (pulled in by `best-practices`) would pin every `FROM`,
  including the internal `ghcr.io/lahaluhem/android-sdk:latest` the flutter image builds on. That
  tag is rebuilt and republished every run and must float, so a `packageRule` sets
  `pinDigests: false` for it. `ubuntu:24.04` stays digest-pinned, which is multi-arch-safe because
  Renovate pins the manifest-list digest.
- **Cadence:** weekly (`schedule:weekly`), down from the old every-2h cron. Stable Flutter ships
  roughly quarterly, so frequent polling was wasteful.
- **CI lint tools:** hadolint and actionlint are pinned the same way. Their versions live as
  `# renovate:`-marked env vars in `.github/workflows/test.yml`, tracked by a second
  `customManagers` entry via the `github-releases` datasource. The install step downloads the exact
  release asset, verifies it against the publisher's `.sha256` / `checksums.txt`, then installs.
  This replaced a step that curled `latest` hadolint and ran `download-actionlint.bash` from
  `main`: unpinned, and a corrupt download once slipped through as a valid-looking HTTP 200 and
  broke a run. Pinning plus checksum verification closes both the supply-chain gap and that flake.
- **Why not lint Actions:** the standard alternative is official Actions like
  `hadolint/hadolint-action`, which `best-practices` would SHA-pin automatically. We pin in the
  workflow instead because `scripts/test.sh lint` is the single source of lint truth, run
  identically locally and in CI, and it invokes `hadolint` / `actionlint` as binaries on `PATH`.
  Pinning the versions in the workflow keeps CI installing the *same* tools `test.sh` runs. A lint
  Action runs the tool its own way, which would either split CI from `test.sh` or force us to
  reconcile the Action's pinned version with whatever `test.sh` installs locally. One coherent
  system beats two kept in sync, and it reuses the custom-manager + `github-releases` mechanism
  already in place for Flutter.

---

<a id="quiet-ci-defaults"></a>
## Quiet-by-default: telemetry off, version check skipped

- **Decision:** the `flutter` image bakes `FLUTTER_SUPPRESS_ANALYTICS=true` + `BOT=true`. Together
  they no-op Flutter *and* Dart analytics and skip Flutter's version-freshness check (a per-job
  network hit in fresh CI containers). Overridable at runtime (`-e BOT=false`).
- **Why `BOT`:** the version check has no dedicated env var (`--no-version-check` is
  per-invocation only), so bot detection is its only bakeable lever. `flutter` and `dart` read the
  same env list via flutter_tools' `BotDetector` / dartdev's `isBot()`
  (`lib/src/base/bot_detector.dart`, an internal lever, not user-facing docs); `BOT=true` trips it,
  covering both the version check and analytics for every user (an env var, not a per-`HOME`
  opt-out file). `FLUTTER_SUPPRESS_ANALYTICS` is the self-documenting belt for Flutter's side.
- **Why not `CI=true`:** redundant and too broad. `BOT` already trips bot detection, so `CI` adds
  nothing for flutter/dart; meanwhile `CI` is honoured by many unrelated tools (npm, test runners),
  so baking it would force everything a consumer runs in the container into CI mode, a runtime
  assumption the portable-image rule avoids. Real CI sets `CI` itself anyway, so baking it would
  only surprise local `docker run`. `BOT` is the surgical pick.

---

<a id="dx-tools-native"></a>
## DX CLIs are compiled to native binaries, not `pub global activate`

- **Decision:** the two Flutter DX tools (`cider`, `dependency_validator`) are compiled to
  self-contained native executables with `dart compile exe` into `/usr/local/bin`, rather than
  installed with `dart pub global activate`.
- **Why:** `pub global activate` doesn't leave a portable binary, it leaves a precompiled snapshot
  keyed to the exact SDK version (the file is literally named
  `…/global_packages/cider/bin/cider.dart-<sdk>.snapshot`). That snapshot lives in `PUB_CACHE`, and
  in CI `PUB_CACHE` is often a shared or persisted cache (a runner-level volume mounted across jobs).
  The moment the SDK and that cache drift apart, the tool breaks with an SDK-mismatch error and stays
  broken until it's re-activated. Two ways they drift: the host SDK is upgraded under a persisted
  cache, or a `pub-cache` volume seeded once from an image outlives a rebuild of that image on a
  newer Flutter (the volume keeps the old snapshot and shadows the image's fresh one). A native
  binary in `/usr/local/bin` neither lives in nor reads `PUB_CACHE`, so it survives SDK upgrades and
  can't be shadowed by a pub-cache volume.
- **How it's built:** activate each tool (only to resolve, download, and generate a
  `package_config.json`), `dart compile exe` the resolved `bin/<exe>.dart` against that config, then
  `pub global deactivate` and drop `global_packages` / `bin` / `hosted` so no snapshot or source
  ships in the image. The image is built natively per arch, so each arch gets its own ELF.
- **Trade-offs:** about 15 MB for the two self-contained binaries, and `dart pub global run` is no
  longer wired up for them (unused here). Versions stay pinned and Renovate-bumped via the `dart`
  datasource, now as `# renovate:`-marked `ENV …_VERSION` lines (the same shape as `YQ_VERSION` in
  the android-sdk image), since the old custom manager keyed off the `activate` lines that are gone.
- **Scope note:** these are pure-Dart tools, so this is arch-agnostic and unrelated to the arm64
  Android-build limitation ([#arm64-android-build-limitation](#arm64-android-build-limitation)).
