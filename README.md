# [Flutter](https://flutter.dev/) + Android SDK Docker images

[![Build images](https://github.com/LahaLuhem/chrysalis/actions/workflows/build_and_push.yml/badge.svg?branch=master)](https://github.com/LahaLuhem/chrysalis/actions/workflows/build_and_push.yml)
[![Test](https://github.com/LahaLuhem/chrysalis/actions/workflows/test.yml/badge.svg?branch=master)](https://github.com/LahaLuhem/chrysalis/actions/workflows/test.yml)
![multi-arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED)
[![ghcr.io: flutter](https://img.shields.io/badge/ghcr.io-lahaluhem%2Fflutter-2496ED?logo=docker&logoColor=white)](https://github.com/LahaLuhem/chrysalis/pkgs/container/flutter)
[![ghcr.io: android-sdk](https://img.shields.io/badge/ghcr.io-lahaluhem%2Fandroid--sdk-2496ED?logo=docker&logoColor=white)](https://github.com/LahaLuhem/chrysalis/pkgs/container/android-sdk)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/LahaLuhem/chrysalis/pulls)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![GitHub issues](https://img.shields.io/github/issues/LahaLuhem/chrysalis.svg)](https://github.com/LahaLuhem/chrysalis/issues)
[![GitHub closed issues](https://img.shields.io/github/issues-closed/LahaLuhem/chrysalis.svg)](https://github.com/LahaLuhem/chrysalis/issues?q=is%3Aissue+is%3Aclosed)
[![GitHub pull requests](https://img.shields.io/github/issues-pr/LahaLuhem/chrysalis.svg)](https://github.com/LahaLuhem/chrysalis/pulls)
[![GitHub closed pull requests](https://img.shields.io/github/issues-pr-closed/LahaLuhem/chrysalis.svg)](https://github.com/LahaLuhem/chrysalis/pulls?q=is%3Apr+is%3Aclosed)

Docker images with Flutter and the Android SDK baked in, for both `linux/amd64`
and `linux/arm64`. They follow the latest stable Flutter and live on GHCR.

They're plain OCI images, so they run anywhere: any CI, any container runtime.

<!-- TOC start (generated with https://github.com/derlin/bitdowntoc) -->

- [Images](#images)
- [Quick start](#quick-start)
- [What's in the image](#whats-in-the-image)
- [Architecture support](#architecture-support)
- [Staying current](#staying-current)

<!-- TOC end -->

## Images

| Image | Tags |
| --- | --- |
| [`ghcr.io/lahaluhem/flutter`](https://github.com/LahaLuhem/chrysalis/pkgs/container/flutter) | `stable`, plus the exact version (`3.44.4`, ...) |
| [`ghcr.io/lahaluhem/android-sdk`](https://github.com/LahaLuhem/chrysalis/pkgs/container/android-sdk) | `latest` |

Every tag is a multi-arch manifest, so `docker pull` grabs the variant matching
your machine on its own.

## Quick start

Run your tests against the current directory:

```bash
docker run --rm -it -v ${PWD}:/build -w /build ghcr.io/lahaluhem/flutter:stable flutter test
```

Want a specific Flutter version instead of `stable`? Swap the tag:

```bash
docker run --rm -it -v ${PWD}:/build -w /build ghcr.io/lahaluhem/flutter:3.44.4 flutter test
```

Pin the platform when you need to (otherwise it follows your host):

```bash
docker run --rm -it --platform linux/arm64 ghcr.io/lahaluhem/flutter:stable flutter doctor
```

## What's in the image

Here's each layer, and why it's there:

| Layer | Why it's there | What's in it |
| --- | --- | --- |
| **Base** | the OS | `ubuntu` |
| **Build toolchain** | build an Android app with Flutter | the JDK, the Android SDK (cmdline-tools, platform-tools, build-tools, a platform), `git`, `zip`/`unzip`, `curl`/`wget`, `build-essential`, `libstdc++6`, `locales` |
| **Convenience (DX)** | handy, but not needed to build | `lcov` (for `flutter test --coverage` reports), `jq` and `yq` (JSON and YAML), plus the Dart CLIs `cider` and `dependency_validator` (see below) |
| **Flutter** | run `flutter`/`dart`, build apps | Flutter cloned at the pinned version plus its bundled Dart SDK. This is the `flutter` image, built `FROM` `android-sdk`. |

> **By architecture:** `flutter`, `dart`, and the JVM tooling run natively on both
> `amd64` and `arm64`. The Android SDK build tools (`aapt2`, `cmake`, the NDK) are
> x86-64-only, so building APKs on `arm64` runs them under emulation. See
> [Architecture support](#architecture-support).

> **Quiet by default:** the `flutter` image ships with analytics off (Flutter and
> Dart) and Flutter's version-update check skipped, so CI runs stay quiet and skip
> the needless network call. Override with `-e BOT=false`.

<details>
<summary>Flutter DX tools</summary>

Two Dart CLIs are shipped as native binaries on `PATH` (compiled with `dart compile exe`).
Handy for project chores, not needed to build:

- [`cider`](https://pub.dev/packages/cider): version bumps and `CHANGELOG.md` management.
- [`dependency_validator`](https://pub.dev/packages/dependency_validator): flags missing,
  unused, or mis-promoted dependencies.

They run like any other command in the image, against your mounted project:

```bash
docker run --rm -v ${PWD}:/build -w /build ghcr.io/lahaluhem/flutter:stable dependency_validator
docker run --rm -v ${PWD}:/build -w /build ghcr.io/lahaluhem/flutter:stable cider bump patch
```

Versions track pub.dev through Renovate, like everything else here.

</details>

## Architecture support

Almost everything runs natively on both arches. The one catch is building
Android apps on arm64.

| Workload | amd64 | arm64 |
| --- | --- | --- |
| `flutter` / `dart`, `flutter test`, `flutter analyze`, `pub`, web builds | native | native |
| Android builds (`flutter build apk` / `appbundle`) | native | needs x86 emulation |

<details>
<summary>Why arm64 Android builds need emulation</summary>

Google only publishes the Linux Android SDK build tools (`aapt2`, `cmake`,
`ninja`, the NDK, `adb`) as x86-64 binaries. There's no arm64 Linux build, so on
a native arm64 host an APK/AAB build eventually reaches for a tool it can't run,
and fails.

The fix is to register x86 emulation on the host once (Docker Desktop comes with
it already):

```bash
docker run --privileged --rm tonistiigi/binfmt --install amd64
```

After that `flutter build apk` works on arm64 too. It's just slower, since those
few tools run emulated while everything else stays native. The full story is in
[APPENDIX.md](APPENDIX.md#arm64-android-build-limitation).

</details>

> **Note:** the Android *emulator* isn't in the arm64 image either. Google
> doesn't ship it for [`linux/arm64`](https://issuetracker.google.com/issues/227219818).

## Staying current

[Renovate](https://docs.renovatebot.com) checks weekly for new stable Flutter releases
and opens a PR bumping [`versions.env`](versions.env). Merge it, and the images rebuild on
the new version. The same config keeps the GitHub Actions pins and the `ubuntu` base image
current.
