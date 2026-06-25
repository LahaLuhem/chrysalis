# Docker Images for [Flutter](https://flutter.dev/)

Multi-arch (`linux/amd64` + `linux/arm64`) Docker images bundling
[Flutter](https://flutter.dev/) and the Android SDK, published to GHCR and
tracking the latest stable Flutter release.

These are standard OCI images — use them with any CI system or OCI runtime.

## Images

| Image | Tags |
| --- | --- |
| [`ghcr.io/lahaluhem/flutter`](https://github.com/LahaLuhem/chrysalis/pkgs/container/flutter) | `stable`, `<flutter-version>` (e.g. `3.44.4`) |
| [`ghcr.io/lahaluhem/android-sdk`](https://github.com/LahaLuhem/chrysalis/pkgs/container/android-sdk) | `latest` |

Both are published as multi-arch manifest lists, so `docker pull` (or any
runtime) automatically resolves the variant matching the host architecture —
no QEMU emulation needed on `arm64` hosts (Apple Silicon, AWS Graviton, etc.).

## Usage

```bash
docker run --rm -it -v ${PWD}:/build --workdir /build ghcr.io/lahaluhem/flutter:stable flutter test
```

The example above mounts the current working directory and runs `flutter test`.

Pin to a specific Flutter version instead of `stable`:

```bash
docker run --rm -it -v ${PWD}:/build --workdir /build ghcr.io/lahaluhem/flutter:3.44.4 flutter build apk --debug
```

Force a specific architecture (defaults to the host's):

```bash
docker run --rm -it --platform linux/arm64 ghcr.io/lahaluhem/flutter:stable flutter doctor
```

> The Android emulator is **not** included in the `arm64` image — it is
> [unavailable for `linux/arm64`](https://issuetracker.google.com/issues/227219818).
> Building APKs/AABs works on both architectures.

## Maintenance

A scheduled workflow checks for new stable Flutter releases and opens a PR
bumping [`versions.env`](versions.env); merging it republishes the images.

This repo is a maintained, multi-arch continuation of
[`davidmartos96/docker-images-flutter`](https://github.com/davidmartos96/docker-images-flutter)
(itself a fork of the now-EOL
[`cirruslabs/docker-images-flutter`](https://github.com/cirruslabs/docker-images-flutter)).
