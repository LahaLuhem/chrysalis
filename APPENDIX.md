<!-- TOC start -->

- [`AGENTS.md` and `CLAUDE.md` are symlinks into `.ai/`](#ai-files-symlinked)
- [Why this fork exists: maintained *and* multi-arch](#why-multi-arch)
- [arm64 Linux builds Android only under x86-64 emulation](#arm64-android-build-limitation)
- [The Android emulator isn't shipped](#no-emulator)
- [cmdline-tools stays at rev 22, and the image deletes `bin/android`](#no-android-cli)
- [Flutter is installed by `git clone`, not the release tarball](#flutter-clone-not-tarball)
- [Everything under the Flutter SDK is owned by root](#root-owned-sdk)
- [Multi-arch via native matrix + push-by-digest + manifest merge](#digest-merge-multiarch)
- [OCI-native images](#oci-native-images)
- [Publishing is gated to `master` and manual dispatch](#publish-gating)
- [`flutter:<x.y>` follows the newest patch on its line](#floating-minor-tag)
- [Every image gets an immutable `sha-<commit>` tag](#sha-tags)
- [`flutter` is built on a pinned `android-sdk` digest](#pinned-base)
- [PRs build `flutter` on the android-sdk from the same checkout](#pr-flutter-build)
- [Version tracking via Renovate, not a bespoke cron](#renovate-version-tracking)
- [Renovate automerges the boring tier, gated on one stable check](#renovate-automerge)
- [`build-tools` is baked to match AGP, but the NDK and CMake aren't](#ndk-cmake-not-baked)
- [The NDK cache is a path we name, not a smaller NDK we ship](#ndk-cache-not-pruned)
- [Quiet-by-default: telemetry off, version check skipped](#quiet-ci-defaults)
- [DX CLIs are compiled to native binaries, not `pub global activate`](#dx-tools-native)
- [Build-env setup helpers: `ch-build-setup-android` + `ch-fetch-firebase-config`](#build-setup-android)

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
  the agent-guidance files under `.ai/` keeps them together, and the root symlinks preserve
  auto-discovery.
- **Committed vs. local:** the `.ai/` canonical files are committed, the root symlinks are
  **gitignored** (`/AGENTS.md`, `/CLAUDE.md` in [`.gitignore`](./.gitignore)), so nothing in
  the build pipeline depends on them. Each contributor (or their agent) recreates the
  symlinks locally:

  ```bash
  ln -s .ai/AGENTS.md AGENTS.md
  ln -s .ai/CLAUDE.md CLAUDE.md
  ```

  A **real file** at the root beats the symlink. If a contributor prefers a committed root
  `AGENTS.md`/`CLAUDE.md`, that works too, and the `.ai/` copies stay the default.
- **Cross-platform note:** symlinks survive `git clone` on macOS/Linux. On Windows hosts
  without symlink support the file shows up as a small text file containing the link target;
  the fallback is real files at root, hand-synced.
- **`CODESTYLE.md` sits at the root, unsymlinked.** Style serves humans and agents alike, so it
  needs no auto-discovery trick.

---

<a id="why-multi-arch"></a>
## Why this fork exists: maintained *and* multi-arch

- **`cirruslabs/docker-images-flutter` was multi-arch but is EOL.** Cirrus Labs is joining
  OpenAI, and the images froze ~2026-05-01. They shipped genuine `linux/amd64` + `linux/arm64`
  manifests (verified via `docker buildx imagetools inspect`), but receive no further
  updates.
- **The `davidmartos96` fork tracks the latest Flutter but is amd64-only.** Its workflow
  hardcodes `platforms: linux/amd64` and the QEMU setup step is commented out.
- **`chrysalis` wants both:** the latest stable Flutter *and* native `arm64`, maintained
  under our own GHCR namespace (`ghcr.io/lahaluhem`). "Native arm64" has a sharp caveat for
  Android builds, see [#arm64-android-build-limitation](#arm64-android-build-limitation).

---

<a id="arm64-android-build-limitation"></a>
## arm64 Linux builds Android only under x86-64 emulation

**Decision (resolved):** ship multi-arch and make the arm64 image *able* to build Android by baking
in the x86-64 runtime libs its (x86-64) Android tools need, so builds work on any host that can
emulate x86-64. Validated on Apple Silicon + OrbStack with a real `flutter build apk --debug` that
produced an APK. It is **emulated, never native**. Do not claim otherwise.

### The wall
Google ships the Linux Android SDK tools (`aapt2`, `aapt`, `zipalign`, `dexdump`, `adb`, `cmake`,
`ninja`, the NDK) as **x86-64 only**, and AGP on arm64 still fetches the `-linux` maven `aapt2`. On
a bare arm64 host `flutter build apk` reaches `:app:configureCMakeDebug[arm64-v8a]` and dies with
`Dynamic loader not found: /lib64/ld-linux-x86-64.so.2`.

### It takes two things, not one
That loader error is the tell.

1. **Host x86-64 emulation.** An x86-64 *static* binary already runs inside an arm64 container on
   OrbStack with no setup, so the emulation is the host's to provide.
2. **x86-64 userland libs in the image.** A *dynamic* x86-64 binary still fails until the image
   carries the loader and libs. `readelf` on the real tools pins the set. `aapt2` needs `libc6` +
   `libgcc-s1`. NDK `clang` adds **`zlib1g`** (`libz.so.1`), and even the default app triggers an
   NDK CMake configure, so it isn't optional. `cmake` statically links its C++ runtime,
   `aapt`/`zipalign` use the `libc++.so` in `build-tools/lib64`, and nothing links `libstdc++.so.6`.

So the baked set is **`libc6` + `libgcc-s1` + `zlib1g`**, in the arm64-guarded layer in
`images/android-sdk/Dockerfile`. amd64 is untouched.

### Host support matrix
| Host | x86-64 emulation | Setup |
| --- | --- | --- |
| Apple Silicon + OrbStack | built-in | none |
| Apple Silicon + Docker Desktop | yes | enable "Use Rosetta…", else QEMU |
| arm64 Linux (Graviton, Pi, CI) | only if registered | `docker run --privileged --rm tonistiigi/binfmt --install amd64` |
| arm64 Linux, nothing registered | none | builds can't run the tools |

### Performance
Most of an Android build is JVM work (Gradle, AGP, `d8`/`r8`) running native arm64. Only the native
tools are emulated, so the overhead tracks how much native code you build: mild on Apple Silicon,
heavier on QEMU.

### Rejected paths
- **Document-only, consumer installs the libs.** Pushes a setup chore onto every user when a tiny
  image layer removes it.
- **Bundle `qemu-user-static` + per-tool wrappers.** Self-contained anywhere, but every native tool
  needs wrapping and each AGP/NDK bump adds more. Host emulation is the low-maintenance floor.
- **A separate lean vs build-capable image.** Three packages isn't worth doubling the build matrix,
  tags and maintenance. Revisit only if a heavy x86-64 NDK is ever bundled.
- **An iOS/macOS `flutter-mac` image.** Not a Docker image at all: iOS needs a macOS VM on Apple
  hardware (Tart), a separate Mac-only product, so do iOS on macOS runners. Config *fetch* stays in
  scope, since `ch-fetch-firebase-config --ios` is a network call rather than a build
  ([#build-setup-android](#build-setup-android)).

### Guards
`images/android-sdk/structure-test.yaml` asserts the x86-64 loader is present, deterministically and
on both arches. `scripts/test.sh image` also runs `aapt2` under emulation on arm64, skipping rather
than failing where the host has none registered.

### Prior art
cirruslabs shipped arm64 manifests with the same x86-64-tool reality but only smoke-tested the
x86_64 path, so their arm64 Android build was never verified. A present manifest is not a verified
build.

---

<a id="no-emulator"></a>
## The Android emulator isn't shipped

- **What:** no `emulator` package. It used to go in on amd64 only, where it was the single biggest
  layer in the image.
- **Why:** it couldn't do anything as shipped. An emulator needs a system image to boot and none was
  baked, so starting it just said "no AVDs". To use one for real you need a system image (1.8 GB for
  android-36 x86_64), an AVD, and `/dev/kvm` in the container. None of that can be baked, so anyone
  emulating was already running an install step. Adding `emulator` to it is one more word and 337 MB
  on top of 1.8 GB they can't dodge. Everyone else paid for it on every pull.
- **What it saved.** A layer-by-layer diff of the published amd64 image against a fresh build shows
  exactly one layer gone, the emulator's, at 859 MB unpacked and 327.4 MB compressed:

  | compressed | before | after |
  | --- | ---: | ---: |
  | `android-sdk:latest` amd64 | 910.0 MB | 582.6 MB |
  | `flutter:stable` amd64 | 2062 MB | ~1735 MB |

  arm64 never had it, so the two arches are near-identical now (580.6 MB and 1736 MB).
- **The risk we took:** `android-sdk` publishes only `:latest`, so anyone who was using the emulator
  has no older tag to fall back on. Judged unlikely for an image whose job is building APKs in CI.
- **The guard:** `structure-test.yaml` asserts the directory is absent, on both arches, on every PR.
  It replaced a longer arch-conditional check in `test.sh` that only ran on whatever arch you were
  sitting on.

---

<a id="no-android-cli"></a>
## cmdline-tools stays at rev 22, and the image deletes `bin/android`

- **Decision:** hold `ANDROID_SDK_TOOLS_VERSION` at rev 22 (`15859902`), keep installing SDK packages
  with `sdkmanager`, deprecated as it is, and delete `bin/android` from the image. Don't move to
  `android sdk install`.
- **What rev 23 actually changed.** One file that matters: `bin/sdkmanager` stopped being a JVM
  launcher and became a shim that hands every install to `bin/android`. That binary is
  byte-identical in rev 22 and rev 23 (same SHA-256), so this isn't an arch regression, rev 23 just
  started calling something that had been sitting there unused. It also drops
  `lib/sdkmanager-classpath.jar` and `lib/sdklib/libsdkmanager_lib.jar`.
- **Why that blocks us:** the image installs packages by running `sdkmanager` during `docker build`,
  and the arm64 leg builds natively with no x86-64 emulation (hard rule 4). On rev 23 those `RUN`
  lines die with `Exec format error`, exit 126.
- **Holding the pin wasn't enough on its own.** The hold covers `docker build`. It does nothing for
  consumer builds, because `bin/android` ships in rev 22 too and flutter_tools picks its SDK tool with
  a bare `existsSync()`. [flutter#191826](https://github.com/flutter/flutter/pull/191826) would then
  hand Gradle `-Pflutter.androidCliPath` and never fall back to `sdkmanager`. Deleting the file is what
  puts that out of reach, on both arches, whatever upstream does.
- **`android` is not the CLI, it's a downloader.** A ~5 MB launcher that fetches the real CLI on
  first use from `dl.google.com/android/cli/latest/<platform>/android-cli`. Measured: 87,324,848 B
  down, **239 MB on disk** once its bundled JRE and 53 MB `main.jar` unpack, every native artifact
  x86-64. Google serves `linux_x86_64` and both darwin builds, so the `linux_aarch64` URL we'd need
  404s.
- **The missing arm64 build is only the first of four problems** with that route:

  | What | Why it hurts here |
  | --- | --- |
  | no Linux arm64 build | the native arm64 build leg can't run it at all |
  | 239 MB on first use | lands in `$ANDROID_USER_HOME` (default `$HOME/.android`), outside every `CH_BUILD_CACHE_*` path |
  | writes one license file | `android-sdk-license` only, where `sdkmanager --licenses` writes seven |
  | metrics on by default | a per-call `--no-metrics` is the only off switch, so nothing to bake ([#quiet-ci-defaults](#quiet-ci-defaults)) |

- **Rev 23 can still install, just not through its wrapper.** `SdkManagerCli` still ships in
  `sdklib/tools.sdklib.jar`. Checked on native arm64 with `bin/android` deleted so nothing could
  quietly fall back to emulation: it wrote all seven license files and installed `platform-tools`
  plus `platforms;android-36`. Treat that as an escape hatch if the hold ever has to lift early, not
  a plan. The entry point prints a deprecation notice and Google is already deleting the jars around
  it.
- **flutter doctor is no longer a reason to hold.** The shim makes `sdkmanager --licenses` a no-op,
  which used to leave `flutter doctor` reporting "Android license status unknown"
  (flutter/flutter#191487, #191558). Fixed in Flutter 3.47.3, which falls back to reading
  `$ANDROID_HOME/licenses`. It says "all accepted" when *any* file there is non-empty, so a green
  doctor tells you nothing about the set being complete. That is what the
  `android-sdk-preview-license` assertion in `structure-test.yaml` is for.
- **The hold has a way out and gets re-checked weekly.** `scripts/check-android-sdk.sh` holds the
  pin instead of flagging it, and files an issue when either exit opens: a rev newer than the one
  the hold was assessed against, or that `linux_aarch64` URL starting to serve.
- **Lifting the hold means dropping the delete, in the same change.** Rev 23's `sdkmanager` is a shim
  over `bin/android`, so a pin bump that leaves the `rm` in place installs nothing.
- **A local arm64 test cannot prove this.** An Apple Silicon host with OrbStack has x86-64 binfmt
  registered, so an x86-64 binary runs fine inside an arm64 container and a local check passes.
  That is exactly how this reached CI. See CLAUDE.md, *Validating arm64*.

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
  Dart source plus shell scripts), and the first `flutter` run bootstraps the **host-arch** Dart SDK
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
  Renovate's `flutter-version` datasource. See
  [#renovate-version-tracking](#renovate-version-tracking) for why that beats Dependabot.
- **Rejected: download the x64 tarball and hand-swap an arm64 Dart SDK.** Unsupported, and the
  tarball's framework expects its bundled Dart, while the clone's bootstrap is the maintained path that
  resolves the correct Dart per arch.

---

<a id="root-owned-sdk"></a>
## Everything under the Flutter SDK is owned by root

- **Decision:** the precache `RUN` ends with a `find … -exec chown -h 0:0`, re-owning anything under
  `FLUTTER_HOME` that isn't `root:root`.
- **Why:** `flutter precache` unpacks its artifact tarballs as root, and GNU tar running as root keeps
  each file's recorded owner. The `gradle_wrapper` artifact carries its build machine's `397546:5000`,
  so 3.47.5 shipped five files with that owner. A Docker host whose ID map stops at 65535
  (userns-remap, rootless, an unprivileged LXC) can't `lchown` to it, so the layer fails to
  extract and the pull fails with `failed to Lchown … invalid argument`. Hosts with the full ID
  range pull it fine, which is why it goes unnoticed.
- **Why in the same `RUN`:** a `chown` in a later layer is too late. The bad owner is already baked
  into the earlier layer, and the host has to extract that one first.
- **Why `find` and not `chown -R`:** chowning a file from the clone layer copies it up into this
  layer. `chown -R` over the whole SDK would duplicate the checkout. `find` touches only the files
  that are wrong, so the layer grows by nothing.
- **Guard:** `structure-test.yaml` fails the build if any file in the image has a UID or GID above
  65535.

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
- **`android-sdk` is published before `flutter` builds.** `flutter` builds `FROM` an android-sdk
  digest, and that digest has to be a manifest list by the time the `flutter` matrix runs, so each
  per-arch build pulls the matching base on its own. Hence the job order build-android →
  merge-android → resolve-base → build-flutter → merge-flutter ([`#pinned-base`](#pinned-base)).
- **`provenance: false`.** Provenance/SBOM attestations add `unknown/unknown` entries to the
  manifest list that muddy `docker manifest inspect`. Disabling them keeps the manifest to
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
  the OCI labels (image config) and annotations, and the Dockerfiles carry no `LABEL`s. The split build
  means metadata attaches in two places: the per-arch push applies labels + manifest-level annotations
  (`DOCKER_METADATA_ANNOTATIONS_LEVELS: manifest`), and the merge applies index-level annotations, fed
  to `imagetools create --annotation "index:..."` (`...LEVELS: index`). `title`/`description` are
  curated per image (from `build_and_push.yml`), while `source`/`revision`/`created`/`version`/`licenses`
  fill in from the repo and the build commit.
- **Two checks keep it honest.** On publish, the merge job runs
  [`scripts/assert_oci_registry.sh`](./scripts/assert_oci_registry.sh) (the index, both arches, and
  every manifest, config, and layer) plus `crane validate --fast` on the pushed image (structural
  validation only: re-downloading every layer to re-hash it cost ~4.5 min per publish for bytes the
  registry digest-checks on push and every client re-checks on pull). At PR time the amd64
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

- **Publish on `master` pushes and `workflow_dispatch`, while pull requests build-validate without
  pushing.** This keeps the shared tags (`android-sdk:latest`, `flutter:stable`,
  `flutter:<version>`) from being clobbered by every branch, while still validating both
  arches on PRs and giving a deliberate manual path to publish/verify a branch
  (`gh workflow run build_and_push.yml --ref <branch>`).
- **Why not push on every branch:** concurrent branch builds would race on the same tags.
  Gating to `master` + explicit dispatch makes publishing intentional.
- **Each image is gated on its own paths.** `prepare` lists the changed files (compare API for
  pushes, PR files API for pull requests), then decides per image. android-sdk: its own dir,
  `scripts/assert_*.sh` (those run inside the publish job), and the two build workflows. flutter:
  all of that, since it builds `FROM` the base, plus its own dir and `versions.env`.
  `scripts/test.sh` and `check-android-sdk.sh` are out on purpose: neither is baked and neither
  runs in a publish, yet 3 of 12 consecutive master commits were `test.sh` edits that republished
  both images.
- **Why bother.** Every publish stamps a fresh `created` label inside the hashed config blob, so a
  byte-identical rebuild still gets a new digest and still moves the tag. Of the 63 master commits
  after the first-day import, 50 republished both images while only 10 touched
  `images/android-sdk/`. Replayed through the new gate they give 23 android-sdk builds and 40
  flutter. 13 of those 23 are pipeline edits rather than content, kept in so the gate keeps the
  property below.
- **The gate can only skip work, never a needed publish.** `workflow_dispatch` builds both, and
  failing to list the changed files falls open to building both. The downstream jobs open their
  `if` with `!cancelled()`, so a *skipped* android-sdk doesn't skip them along with it. A *failed*
  one still does.
- **Verification:** a publish is only "done" once `docker manifest inspect <ref>` shows both
  `linux/amd64` and `linux/arm64`. Never report success without it.

---

<a id="floating-minor-tag"></a>
## `flutter:<x.y>` follows the newest patch on its line

- **What:** each publish tags flutter three ways, in this order: `3.47.1`, `3.47`, `stable`.
  `3.47` moves to whatever the newest 3.47 patch is. Debian and Ubuntu tag point releases the
  same way.
- **Why:** stable Flutter patches land about weekly (3.44.0 to 3.44.9 was ten releases in 80
  days). Without an `<x.y>` tag you either take `stable` and get moved onto a new minor whenever
  one lands, or pin an exact version and bump it every week. This sits in between.
- **Keep the exact version first in the tag list.** It's what ends up in the image's version
  label, and the merge job's inspect and verify steps only look at the first tag. Flip the order
  and every image claims to be `3.47` while the OCI checks run against the wrong ref. A PR won't
  catch it either. PRs build flutter but never tag it, so the tag list is first tried on the
  publish after merge.
- **Old `<x.y>` tags go quiet.** `3.44` sits at `3.44.9` forever once 3.47 ships, and nobody gets
  told. That matches how Flutter works: a minor line is done when the next one starts (checked
  all 190 stable releases, it has never gone back).
- **Not doing:** a bare `3` tag, since Flutter has been 3.x since 2022 and it would just be
  `stable` again. Nor a second pin in `versions.env`, which can drift from `FLUTTER_VERSION`
  when we can derive it instead.

---

<a id="sha-tags"></a>
## Every image gets an immutable `sha-<commit>` tag

- **What:** each publish adds `sha-<first 7 of the commit>` next to the moving tags. android-sdk
  puts it first so `org.opencontainers.image.version` names the build instead of reading `latest`,
  flutter last behind the exact version ([`#floating-minor-tag`](#floating-minor-tag)).
- **Why:** nothing else in the registry stays put. Every publish writes a fresh `created` label
  into the hashed config blob, so even an unchanged rebuild gets a new digest and every tag slides
  onto it. `flutter:3.47.1` was found sitting 12 commits past the 3.47.1 bump. With no fixed tag
  there's no rollback and no way to say which image a build used.
- **Why the commit and not a version.** android-sdk has no single version, and its pins barely
  move: `ANDROID_PLATFORM_VERSION` and `ANDROID_BUILD_TOOLS_VERSION` have never changed while
  `latest` moved 45 times in 65 days, so `android-sdk:36` would read like a pin and behave like
  `latest`. They don't describe the image fully anyway, since `sdkmanager platform-tools` and apt
  both grab whatever is newest at build time.
- **Not bulletproof.** A re-run on the same commit re-points that commit's tag. They also pile up
  at ~380 a year, so [`cleanup-packages.yml`](./.github/workflows/cleanup-packages.yml) drops them
  after six months.

---

<a id="pinned-base"></a>
## `flutter` is built on a pinned `android-sdk` digest

- **What:** [`images/flutter/Dockerfile`](./images/flutter/Dockerfile) does `FROM ${base_ref}`. A
  `base` job resolves `android-sdk:latest` to its index digest once, and both arch builds get that
  same `name@sha256:...`. The arg defaults to the `:latest` tag so a plain `docker build` still
  works, and `scripts/test.sh` passes the image it just built.
- **Why:** the two arch legs used to resolve `:latest` themselves, on separate runners, with
  nothing making them agree. A publish racing another one could ship an amd64 half and an arm64
  half built on different bases.
- **Why resolve instead of plumbing the digest through.** The per-image gate
  ([`#publish-gating`](#publish-gating)) can skip android-sdk, so there isn't always a digest from
  this run to pass on. Reading `:latest` once android-sdk has settled covers both cases with one
  code path.

---

<a id="pr-flutter-build"></a>
## PRs build `flutter` on the android-sdk from the same checkout

- **The hole:** flutter used to build only on publishes, so a Renovate `versions.env` bump
  automerged having validated nothing about it. Building it on PRs was rejected because the only
  base available was the published `android-sdk:latest`, wrong on a PR that changes android-sdk.
- **What changed:** `base_ref` ([`#pinned-base`](#pinned-base)) lets a flutter build sit on any
  android-sdk, pushed or not. On a non-publish run `build-image.yml` builds the base from this
  checkout and hands it over, driven by two optional inputs, `base-name` and `base-context`.
- **Why an OCI layout and not a loaded tag.** `setup-buildx-action` gives us a **docker-container**
  builder, which resolves `FROM` against registries only. A tag in the runner's daemon is invisible
  to it, and so is `--build-context ref=docker-image://<local tag>`. Both fail with
  `pull access denied`. Only `--build-context <name>=oci-layout://<dir>` works. A local check won't
  show this: a dev box's default builder is usually the `docker` driver, which shares the daemon's
  images and hides the problem.
- **Cost:** on a fully cached run, 32s to rebuild the base and 4s to export it, on top of flutter's
  own 85s. Both jobs share the `android-sdk-<arch>` cache scope. Publishes skip it all.

---

<a id="renovate-version-tracking"></a>
## Version tracking via Renovate, not a bespoke cron

- **Decision:** Renovate (`config:best-practices`, Mend-hosted) owns every version bump, replacing
  a hand-rolled `update_flutter_versions.sh` + cron. Config:
  [`.github/renovate.jsonc`](./.github/renovate.jsonc).
- **Why:** one tool instead of a script here and a cron there, and the preset SHA-pins Actions and
  digest-pins the `ubuntu` base, which the old cron never did.
- **Why not Dependabot:** the Flutter pin is a bare string in `versions.env` consumed as a
  `git clone --branch` tag. No Dependabot ecosystem parses that and it has no custom-manager escape
  hatch. Renovate's custom manager plus the `flutter-version` datasource do.
- **The pin only ever moves to a stable release,** because `flutter-version` marks only the
  `stable` channel stable and Renovate skips unstable by default. The `versions.env` lint in
  `scripts/test.sh` backstops it by rejecting any non-`x.y.z` value.
- **One exclusion:** `docker:pinDigests` would pin the `ghcr.io/lahaluhem/android-sdk:latest`
  fallback `FROM`, which is republished every run and must float, so a `packageRule` turns it off
  for that tag. Publishes never use the fallback anyway, they pass a resolved digest
  ([`#pinned-base`](#pinned-base)). `ubuntu` stays pinned to its manifest-list digest, so it stays
  multi-arch-safe.
- **Weekly, except Flutter.** Flutter ships a stable about every 8 days (12 between 2026-06-01 and
  2026-08-27) and republishing when it moves is the whole job, so a `packageRule` exempts it from
  the window. Everything else batches.
- **Lint tools come from one pinned image.** All four linters plus `container-structure-test` live
  in [Linterpol](https://github.com/LahaLuhem/linterpol), pinned in
  [`.github/lint-tools.env`](./.github/lint-tools.env) and read by both `scripts/test.sh` and
  `build-image.yml`. It replaced per-tool installs that curled `latest`, where a corrupt download
  once slipped through as a valid-looking HTTP 200 and broke a run.
- **Grouping:** everything under `images/` batches into one PR, since each merge republishes and N
  PRs cost N publishes. The Flutter pin stays alone, because its PR title is the release note for
  the whole repo.
- **Checking this file:** `scripts/test.sh renovate` runs `renovate-config-validator`. Opt-in, since
  the image is ~1.3 GB and the file changes a few times a year. **Run it from the repo root**, or it
  reads the file as a *global* config and waves almost anything through. It catches unknown options
  and broken regexes, not bad enum values.
- **Why not lint Actions:** `scripts/test.sh lint` is the single source of lint truth and runs every
  linter inside the Linterpol container, so local and CI execute the same bytes, not merely the same
  version number. A lint Action would either split the two or need its pin reconciled with the
  image's. It also keeps linters off the host: `lint` needs nothing but Docker.

---

<a id="renovate-automerge"></a>
## Renovate automerges the boring tier, gated on one stable check

- **Decision:** Renovate automerges everything under a major through GitHub's native auto-merge
  (`platformAutomerge`, `automergeStrategy: "rebase"`). `major` still comes to a human.
- **Why:** hand-merging a weekly digest re-pin is toil with no judgement in it.
- **Merging here publishes** ([#publish-gating](#publish-gating)), so automerge is auto-publishing.
  That is safe because `build-image.yml` structure-tests both arches *before* it pushes, and the
  manifest merge runs only once both legs pass. A bad bump costs a red `master`, never a bad tag.
  (The sibling [`linterpol`](https://github.com/LahaLuhem/linterpol) repo publishes on a tag
  instead, so its automerge carries no such weight.)
- **Why `minor` automerges too:** CI is the guard and it doesn't care what kind of bump it is. Both
  images are built and structure-tested on the PR, on both arches
  ([`#pr-flutter-build`](#pr-flutter-build)). The old worry, that a minor shifts the toolchain under
  every consumer, is the tag's job now: pin `flutter:<x.y>`
  ([#floating-minor-tag](#floating-minor-tag)).
- **`ubuntu` is held to LTS tags.** `26.04` to `26.10` reads as a *minor*, so it would ride along
  with the rule above, but an interim release gets 9 months of support instead of 5 years and no CI
  can see that, because nothing breaks. An `allowedVersions` regex (even year plus `.04`) keeps only
  LTS in scope, so `26.04` to `28.04` stays a major.
- **`images-ok` exists because reusable-call check names aren't stable.** `android-sdk` and
  `flutter` are `workflow_call` jobs, so the contexts they report change with the path gate: one
  name when skipped, three (`build (linux/amd64)`, `build (linux/arm64)`, `merge`) when it runs. A
  ruleset can only name fixed contexts, so requiring either spelling blocks every PR reporting the
  other. `images-ok` in [`build_and_push.yml`](./.github/workflows/build_and_push.yml) `needs` all
  three with `if: always()`, fails only on `failure` or `cancelled`, and so reports under one name
  every time.
- **The ruleset is load-bearing, not decoration.** GitHub auto-merge waits only on *required*
  checks and ignores failing ones that aren't, so automerge with nothing required would merge broken
  builds. `master` requires `lint` and `images-ok` and nothing else. Renaming either job silently
  un-gates automerge, which is why it is a hard rule and not a comment.
- **`automergeStrategy: "rebase"`** because the ruleset requires linear history. It also needs
  "Allow rebase merging" on the repo: with it off, GitHub refuses the auto-merge call and Renovate
  falls back to its own, which merges on its reading of branch status rather than the ruleset's.
- **Rejected: decoupling publish from merge** (publish on a tag, as linterpol does). It would make
  automerge trivially safe, but this repo exists to republish when Flutter moves, so it only moves
  the manual step from merging the PR to cutting the tag.

---

<a id="ndk-cmake-not-baked"></a>
## `build-tools` is baked to match AGP, but the NDK and CMake aren't

- **Decision:** bake the `build-tools` revision **AGP asks for**, and do **not** bake the NDK or CMake,
  even though a bare `flutter build apk --debug` fetches both mid-build. So
  `scripts/check-android-sdk.sh` tracks the platform, holds cmdline-tools, and leaves build-tools
  alone.
- **Why `build-tools` follows AGP, not the manifest.** AGP picks a revision and downloads it when
  absent, so a pin *ahead* of AGP's request is worse than useless: the baked copy goes unused and
  the build fetches AGP's choice anyway. Measured on Flutter 3.44.8 (AGP 9.0.1, wants `36.0.0`):
  pinning `36.1.0` produced `Installing Android SDK Build-Tools 36 in .../build-tools/36.0.0` on
  every build. "Newest in the manifest" is the wrong question for this pin.
- **What the un-baked downloads cost**, measured on this repo's `android-sdk` image:

  | Package | Download | Installed | Pulled because |
  | --- | --- | --- | --- |
  | `ndk;28.2.13676358` | 688.8 MiB | **2.92 GiB** | the app template sets `ndkVersion = flutter.ndkVersion`, and Flutter makes AGP fetch it even with zero native code ([#ndk-cache-not-pruned](#ndk-cache-not-pruned)) |
  | `cmake;3.22.1` | 22 MB | 60 MB | AGP's built-in default, fetched alongside the NDK although a template app has no Android CMake project (its only `CMakeLists.txt` are Linux/Windows desktop) |

- **The `apk` target caches the NDK in a named volume** (`chrysalis-test-ndk`) mounted at
  `$ANDROID_HOME/ndk`. That subdir only: a volume over the whole `$ANDROID_HOME` would hide the
  baked SDK. Before this, every run re-downloaded the NDK and one dropped connection killed the
  build (#52, seen 1 run in 4). Measured: cold 424s with one
  `Installing NDK`, warm 270s with none. Holds one NDK per Flutter version at ~2.9 GB, so it grows
  across bumps and `scripts/test.sh clean` drops it. `APK_CACHE=0` forces the cold path.
- **The CMake row above is historical.** Measured on Flutter 3.44.8. On 3.47.1 a template app no
  longer pulls CMake at all: a cache volume mounted there came back with zero entries, so there is
  nothing to cache and no CMake mount. The guard's allowlist still permits it, so if AGP starts
  asking again the build stays green and the download simply comes back.
- **Why baking them was rejected: runner caching already absorbs it.** Baking grows the `flutter`
  image from ~3.3 GB to ~5.5 GB unpacked on **both** arches, paid on every pull forever, to save a
  download that a warm SDK/Gradle cache pays once. Wrong side of the deal, and 5.5 GB is far
  outside normal range for a CI image. Confirms the earlier call not to bundle a heavy NDK
  ([#arm64-android-build-limitation](#arm64-android-build-limitation), *Rejected paths*), now with
  numbers.
- **If that ever changes** (ephemeral uncached runners), the NDK needs no new pin: its version is
  readable from the Flutter clone the image already carries, at
  `$FLUTTER_HOME/packages/flutter_tools/lib/src/android/gradle_utils.dart` (`const ndkVersion`,
  mirrored in `gradle/src/main/kotlin/FlutterExtension.kt`), so a `RUN` can derive it and stay
  correct across Flutter bumps. CMake would need a manual pin, since Flutter never references it.
- **Guard:** `scripts/test.sh apk` fails if Gradle installs anything under `/opt` except the NDK or
  CMake, turning a pin that drifts from AGP's request into a red test rather than a silent
  per-build download. That allowlist is this decision in executable form.
- **What consumers get instead of a bake:** the path, as `CH_BUILD_CACHE_NDK`
  ([#ndk-cache-not-pruned](#ndk-cache-not-pruned)).

---

<a id="ndk-cache-not-pruned"></a>
## The NDK cache is a path we name, not a smaller NDK we ship

- **Decision:** bake `CH_BUILD_CACHE_NDK=$ANDROID_HOME/ndk` so a build job can cache that folder,
  and leave what's inside it alone. Shipping a trimmed NDK was measured and rejected (below).
- **Why the NDK gets pulled at all, with zero native code in the app.** Flutter asks for it on
  purpose. `FlutterPluginUtils.forceNdkDownload` points `externalNativeBuild.cmake.path` at an empty
  `gradle/src/main/scripts/CMakeLists.txt` whose own comment says it exists "to trick the Android
  Gradle Plugin to download the NDK". AGP needs the NDK to strip debug symbols out of the engine's
  prebuilt `.so`, but only fetches it by itself when it thinks it has to *compile* something native.
- **What it costs**, measured on `flutter:stable` 3.47.4, NDK `28.2.13676358`:

  | | |
  | --- | --- |
  | download from Google | 688.8 MiB (repository manifest) |
  | unpacked on disk | 2.92 GiB over 8,450 files, no symlinks and no hardlinks, so `clang`, `clang++` and `clang-19` are three identical 135 MB copies |
  | as a cache blob | 488 MiB with `zstd -T0 --long=30`, the flags `actions/cache` uses |

  Caching moves about 29% fewer bytes than re-fetching, which is the weaker half of the case. The
  better half: a cache hit means no call to Google mid-build at all, which is the flakiness in #52.
- **A half-restored cache is not repaired, it fails the build.** `_getInstalledNdkVersionsForGradle`
  decides "already installed" from the folder name under `$ANDROID_HOME/ndk` plus a
  `source.properties` inside it, and never looks at the toolchain. A partial restore passes that
  check, skips provisioning, then dies minutes later on a missing `llvm-strip`. Hence the
  all-or-nothing wording in the README. That same function reads `$ANDROID_HOME/ndk` and nothing
  else, so `ANDROID_NDK_ROOT` will not relocate the cache.
- **Pruning: measured, rejected on the native-code case.** A template app runs exactly one thing out
  of that 2.92 GiB, `llvm-strip` (5.9 MB, byte-identical to `llvm-objcopy`, it's one multi-call
  binary). Four `flutter build apk --debug` runs, same image, varying only the ndk dir:

  | ndk dir | pure-Dart app | app with native code |
  | --- | --- | --- |
  | full, 2.92 GiB | green, APK 150,414,216 B | green, fetches CMake |
  | `source.properties` only, 24 KB | fails at `:app:stripDebugDebugSymbols` | not run |
  | `llvm-strip` + `llvm-objcopy`, 11.3 MB | green, same APK byte for byte | not run |
  | `llvm-strip` only, 5.6 MB | green, same APK byte for byte | **fails** `[CXX1429]` at `configureCMakeDebug`, and never re-downloads |

  So a pruned NDK is not a small NDK, it is a broken one that the check reports as present. Baking
  it would turn "fetches what it needs" into "hard fails" for anyone with an ffi plugin or a CMake
  build, which is not a trade a published image gets to make for its users. Offering it as an
  opt-in helper has the same hole, plus it would pin us to AGP's current choice of `llvm-strip`, so
  an AGP that reaches for a different tool breaks every opted-in consumer at once. Scope: `--debug`
  only, one host.
- **Build upward:** a good cache key wants the NDK version, which today only lives in
  `gradle_utils.dart` ([#ndk-cmake-not-baked](#ndk-cmake-not-baked) has the path). Keying on the
  Flutter version works but throws the cache away on every patch bump. Exposing it is not a
  one-liner, because Dockerfile `ENV` cannot take a value from a `RUN`, so it needs a file, a build
  arg, or another helper. Not worth building until someone asks.

---

<a id="quiet-ci-defaults"></a>
## Quiet-by-default: telemetry off, version check skipped

- **Decision:** the `flutter` image bakes `FLUTTER_SUPPRESS_ANALYTICS=true` + `BOT=true`. Together
  they no-op Flutter *and* Dart analytics and skip Flutter's version-freshness check (a per-job
  network hit in fresh CI containers). Overridable at runtime (`-e BOT=false`).
- **Why `BOT`:** the version check has no dedicated env var (`--no-version-check` is
  per-invocation only), so bot detection is its only bakeable lever. `flutter` and `dart` read the
  same env list via flutter_tools' `BotDetector` / dartdev's `isBot()`
  (`lib/src/base/bot_detector.dart`, an internal lever, not user-facing docs). `BOT=true` trips it,
  covering both the version check and analytics for every user (an env var, not a per-`HOME`
  opt-out file). `FLUTTER_SUPPRESS_ANALYTICS` is the self-documenting belt for Flutter's side.
- **Why not `CI=true`:** redundant and too broad. `BOT` already trips bot detection, so `CI` adds
  nothing for flutter/dart. Meanwhile `CI` is honoured by many unrelated tools (npm, test runners),
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

---

<a id="build-setup-android"></a>
## Build-env setup helpers: `ch-build-setup-android` + `ch-fetch-firebase-config`

- **Decision:** the `flutter` image ships `ch-build-setup-android` on `PATH`. It writes the files an
  Android `flutter build apk|aab` expects (a `--dart-define-from-file` file,
  `android/app/google-services.json`, dev signing) from `CH_BUILD_*` env vars, and does nothing
  until a build job calls it. `ch-fetch-firebase-config` does the Firebase half and runs standalone.
- **Why it is in scope though it looks like consumer logic.** The portable-image rule
  ([#quiet-ci-defaults](#quiet-ci-defaults)) bans *runtime assumptions*, not inert tools you opt
  into by name. Same shape as the DX CLIs ([#dx-tools-native](#dx-tools-native)): on `PATH`, no
  effect until called, no CI system assumed. So it sits with `cider`, not with `CI=true`.
- **Three lanes, two opt-in, signing always-on.** dart-defines and google-services do nothing unless
  their vars are set (a partial Firebase set is a fail-fast error). Signing always runs because it
  only mints a local throwaway keystore, no credential and no network, so there is nothing worth
  opting out of. Gating it behind a required password is a possible later mode.
- **dart-defines need no invented format.** flutter_tools picks JSON vs `.env` by
  [content, not file extension](https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/runner/flutter_command.dart)
  (a leading `{`), and both branches end up as the same `KEY=value` define. So the helper writes
  plain per-key lines verbatim: no delimiter to invent, no base64. The lane lives in a standalone
  `ch-write-dart-defines`, so a job that only needs the env file (an iOS build on a macOS runner,
  say) can curl it without dragging in keytool.
- **google-services is fetched, not pasted as a blob.** An earlier "whole file in one secret" var
  was replaced by a build-time call to the Firebase Management API, which keeps the config in sync
  and the blob out of the secret store. The Firebase CLI is deliberately not installed for it: the
  standalone binary is ~250 MB and x86-64-only (so, emulated on arm64 for one HTTP GET), and the npm
  route drags Node into both images. One authenticated request needs only `curl` + `jq` + `openssl`.
- **The IAM floor is one permission, measured.** A probe service account holding only
  **`firebase.clients.get`** fetched the config, which also proved five other candidate permissions
  unnecessary. The stock *Firebase Viewer* role includes it. Auth is a self-signed JWT rather than a
  key file, and it reads only `client_email` and `private_key`, so those are the only inputs.
- **One fetcher for both platforms.** getConfig differs only in the resource segment and the output
  path, and the credential is project-scoped, so `ch-fetch-firebase-config --android|--ios` covers
  both (verified: one service account fetched an Android and an iOS config). `CH_BUILD_FIREBASE_*`
  is shared and only the app id is per-platform. `--ios` ships even though iOS *building* is out of
  scope, because a network call is still useful on a macOS runner.
- **The private key is taken in any shape a CI variable can hold:** a PEM, `\n`-escaped, base64 of a
  PEM, or a bare base64 body. Some CI variable UIs reject the spaces in the
  `-----BEGIN PRIVATE KEY-----` header, hence the header-less form. It is normalised in-shell and
  piped to `openssl`, never written to disk.
- **The fetch skips an existing config, the dart-define writer overwrites.** Firebase config is
  stable per project, so re-fetching burns a JWT and two round-trips for nothing. Dart-defines are
  meant to change between builds, so skipping would silently keep stale values. Signing follows the
  fetch and leaves an existing keystore alone.
- **Keystore is generate-if-absent, and its path is published for caching.** `keytool` mints a fresh
  random keypair every run, so regenerating per job gives an unstable signing key whatever the
  password. Cache `CH_BUILD_CACHE_KEYSTORE` to keep one key across runs.
- **PKCS12 only, one password.** JKS is deprecated, and PKCS12 uses one password for both store and
  key, so the two password vars collapsed into `CH_BUILD_ANDROID_KEYSTORE_PASSWORD` and the classic
  mismatch footgun is gone. Validated with `apksigner`, the tool Gradle actually signs with. A full
  `--release` build could not confirm it end to end on arm64, which is the image's known limitation
  ([#arm64-android-build-limitation](#arm64-android-build-limitation)), not a signing problem.
- **Why `CH_BUILD_CACHE_*` names paths.** The keystore is invisible to the user except as something
  to cache, so it is named for that. The prefix now also covers the two Gradle paths
  (`caches/modules-2`, `wrapper/dists`) and the NDK ([#ndk-cache-not-pruned](#ndk-cache-not-pruned)).
  Caching all of `~/.gradle` was rejected, since it also holds daemon logs, lock files and execution
  history, churn with no payoff. Build-command paths get their own var
  (`CH_BUILD_DART_DEFINE_FILE`): a child process cannot export into the parent job shell, but a
  baked constant can be read by both sides.
- **No direnv, one in-script var registry instead.** direnv loads env for interactive shells and
  manages no defaults or schema, which is the actual problem as the `CH_BUILD_*` surface grows. So
  the defaults, `--help`, and the README table all derive from one source of truth in the script,
  in pure shell with no new image dependency.
