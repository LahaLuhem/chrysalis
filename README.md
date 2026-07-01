# [Flutter](https://flutter.dev/) + Android SDK Docker images

[![Build images](https://github.com/LahaLuhem/chrysalis/actions/workflows/build_and_push.yml/badge.svg?branch=master)](https://github.com/LahaLuhem/chrysalis/actions/workflows/build_and_push.yml)
[![Test](https://github.com/LahaLuhem/chrysalis/actions/workflows/test.yml/badge.svg?branch=master)](https://github.com/LahaLuhem/chrysalis/actions/workflows/test.yml)
![multi-arch](https://img.shields.io/badge/arch-amd64%20%7C%20arm64-2496ED)
![OCI image spec](https://img.shields.io/badge/OCI-image%20spec%20v1-2496ED)
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

They're OCI-native images (OCI media types, standard labels and annotations), so they
run anywhere: any CI, any container runtime.

<!-- TOC start (generated with https://github.com/derlin/bitdowntoc) -->

- [Images](#images)
- [Quick start](#quick-start)
- [What's in the image](#whats-in-the-image)
- [Preparing an Android build](#preparing-an-android-build)
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

## Preparing an Android build

A `flutter build apk` / `appbundle` usually needs a few secret files staged first: a
`--dart-define-from-file` file, `android/app/google-services.json`, and a signing keystore with
`android/key.properties`. Rather than hand-writing that in every CI job, the image ships
**`ch-build-setup-android`**, an opt-in helper that materialises them from `CH_BUILD_*`
environment variables. Call it once before your build; it does nothing until you do, so non-build
jobs pay nothing.

```bash
# in your build job, before `flutter build`:
ch-build-setup-android
flutter build apk --release --dart-define-from-file="$CH_BUILD_DART_DEFINE_FILE"
```

`ch-build-setup-android --help` lists every variable; `--dry-run` shows what it would write
without writing anything.

### What it reads

| Variable | What it does |
| --- | --- |
| `CH_BUILD_DEFINE_<KEY>` | one per dart-define, written verbatim as `<KEY>=<value>`; set as many as you need |
| `CH_BUILD_ANDROID_FIREBASE_APP_ID`, `CH_BUILD_FIREBASE_CLIENT_EMAIL`, `CH_BUILD_FIREBASE_PRIVATE_KEY` | fetch `google-services.json` from Firebase; see [Google Services](#google-services-firebase) |
| `CH_BUILD_ANDROID_KEYSTORE_PASSWORD` | PKCS12 keystore password (default `storepassword`) |
| `CH_BUILD_ANDROID_KEY_ALIAS` | signing key alias (default `development`) |
| `CH_BUILD_ANDROID_DNAME`, `_KEY_VALIDITY`, `_KEY_SIZE`, `_KEY_ALG` | `keytool` knobs, all sensibly defaulted |

Two paths are baked into the image as environment variables, so you reference them instead of
hardcoding a location:

| Variable | Default | Use it for |
| --- | --- | --- |
| `CH_BUILD_DART_DEFINE_FILE` | `lib/env/dart_defines.env` | pass to `--dart-define-from-file` |
| `CH_BUILD_CACHE_KEYSTORE` | `android/app/ch-signing.p12` | add to your build job's cache to keep one signing key across runs |

### Google Services (Firebase)

Rather than pasting the whole `google-services.json` into a CI secret, the helper fetches it from
Firebase at build time (one authenticated call to the Firebase Management API) and writes
`android/app/google-services.json`. You give it the Android app id and a service-account
credential:

| Variable | What it is |
| --- | --- |
| `CH_BUILD_ANDROID_FIREBASE_APP_ID` | the Android app id, e.g. `1:1234567890:android:abc123` |
| `CH_BUILD_FIREBASE_CLIENT_EMAIL` | the service account's `client_email` |
| `CH_BUILD_FIREBASE_PRIVATE_KEY` | its `private_key`; escaped `\n` or real newlines both work |

The credential is project-scoped, so `CH_BUILD_FIREBASE_*` is shared across platforms and only the
app id is Android-specific. All three go together: set none and the step is skipped (a committed
`google-services.json` is left in place); set some but not all and it fails fast.

The service account needs a single permission, `firebase.clients.get` (the predefined *Firebase
Viewer* role includes it, and nothing more is required). There's no Firebase CLI in the image; the
fetch is done by a small standalone helper, `ch-fetch-firebase-config`, that needs only
`curl`/`jq`/`openssl`. `ch-build-setup-android` calls it with `--android`, but it runs on its own
too (handy on a non-chrysalis runner, where you can fetch it straight from the repo):

```bash
ch-fetch-firebase-config --android            # -> android/app/google-services.json
ch-fetch-firebase-config --android --dry-run  # show what it would do, fetch nothing
```

The same fetcher handles iOS: `ch-fetch-firebase-config --ios` writes
`ios/Runner/GoogleService-Info.plist` from `CH_BUILD_IOS_FIREBASE_APP_ID` and the same shared
credential. iOS builds need macOS, so that path is for a macOS runner; chrysalis's own images build
Android on Linux.

<details>
<summary>Creating the service account</summary>

In the Google Cloud console for your Firebase project:

1. **IAM & Admin → Service Accounts → Create service account.**
2. Grant it a role that includes `firebase.clients.get`: the predefined **Firebase Viewer** works,
   or a custom role with just that one permission.
3. **Keys → Add key → Create new key → JSON**, and download it.
4. Copy `client_email` and `private_key` from that JSON into `CH_BUILD_FIREBASE_CLIENT_EMAIL` and
   `CH_BUILD_FIREBASE_PRIVATE_KEY`. The app id is in the Firebase console under Project settings.

</details>

### Signing

The helper generates a PKCS12 dev keystore and writes the `key.properties` that your
`android/app/build.gradle` reads (you still need the [standard signing
config](https://docs.flutter.dev/deployment/android#sign-the-app) wired into your project). It
only generates when the keystore is missing, so caching `CH_BUILD_CACHE_KEYSTORE` keeps the key
stable; otherwise each run mints a fresh one and installed builds can't update in place.

<details>
<summary>Things to watch out for</summary>

- **Run it from your project root** (it looks for `pubspec.yaml`).
- **dart-define values are written verbatim.** Quote a value that contains a `#` or has leading or
  trailing spaces; multi-line values aren't supported by `--dart-define-from-file`.
- **An existing `android/key.properties` is left untouched**, so your own signing setup wins.
- **Changing the password invalidates a cached keystore.** Clear the cache when you rotate it; the
  old keystore won't open with the new password.
- **The files it writes contain secrets** (mode `0600`). On a reused/persistent runner, clean them
  up after the build.
- **Release builds on arm64 need x86 emulation**, like any Android build here (see
  [Architecture support](#architecture-support)).

</details>

### Caching Gradle (optional, for speed)

Gradle downloads its dependencies and its own distribution on the first build. Two paths are baked
in so a build job can cache them across runs (`GRADLE_USER_HOME` is pinned to `/root/.gradle`):

| Variable | Points to |
| --- | --- |
| `CH_BUILD_CACHE_GRADLE_MODULES` | `$GRADLE_USER_HOME/caches/modules-2`, the downloaded dependencies |
| `CH_BUILD_CACHE_GRADLE_DISTS` | `$GRADLE_USER_HOME/wrapper/dists`, the Gradle distribution the wrapper fetches |

These are deliberately narrow: caching all of `~/.gradle` would also drag in daemon logs, lock
files, and execution history you don't want.

> **Mind the cache size.** The dependency cache (`modules-2`) can run to several GB. On a
> single-project ephemeral runner that's usually fine, but check that caching it (uploaded and
> downloaded every run) actually beats re-fetching, otherwise the cache itself becomes the
> bottleneck.

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
