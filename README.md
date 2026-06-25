# [Flutter](https://flutter.dev/) + Android SDK Docker images

Docker images with Flutter and the Android SDK baked in, for both `linux/amd64`
and `linux/arm64`. They follow the latest stable Flutter and live on GHCR.

They're plain OCI images, so they run anywhere: any CI, any container runtime.

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
| **Base** | the OS | `ubuntu:24.04` |
| **Build toolchain** | build an Android app with Flutter | JDK 21, the Android SDK (cmdline-tools, platform-tools, build-tools 36, platform android-36), `git`, `zip`/`unzip`, `curl`/`wget`, `build-essential`, `libstdc++6`, `locales` |
| **Convenience (DX)** | handy, but not needed to build | `lcov` (for `flutter test --coverage` reports), `jq` |
| **Flutter** | run `flutter`/`dart`, build apps | Flutter cloned at the pinned version plus its bundled Dart SDK. This is the `flutter` image, built `FROM` `android-sdk`. |

> **By architecture:** `flutter`, `dart`, and the JVM tooling run natively on both
> `amd64` and `arm64`. The Android SDK build tools (`aapt2`, `cmake`, the NDK) are
> x86-64-only, so building APKs on `arm64` runs them under emulation. See
> [Architecture support](#architecture-support).

<details>
<summary>Planned: Flutter DX tooling</summary>

Convenience tools we may add later as global Dart packages
(`dart pub global activate ...`), like [cider](https://pub.dev/packages/cider) for
changelog and version bumps. Nothing installed yet; noted so there's an obvious home
for it when the time comes.

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

A scheduled job checks for new stable Flutter releases every couple of hours and
opens a PR bumping [`versions.env`](versions.env). Merge it, and the images
rebuild on the new version.

<details>
<summary>Where this repo comes from</summary>

It's a maintained, multi-arch continuation of
[davidmartos96/docker-images-flutter](https://github.com/davidmartos96/docker-images-flutter),
which forked the now-retired
[cirruslabs/docker-images-flutter](https://github.com/cirruslabs/docker-images-flutter).
The davidmartos96 fork follows the latest Flutter but ships amd64 only; cirruslabs
was multi-arch but isn't maintained anymore. This one goes for both: current
Flutter and real arm64.

</details>
