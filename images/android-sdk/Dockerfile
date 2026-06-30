# Android SDK image: Ubuntu + cmdline-tools, platform-tools, build-tools, a platform.
# This is the base layer the flutter image builds FROM. The SDK build tools are
# x86-64-only on Linux; see ../../APPENDIX.md#arm64-android-build-limitation.
#
# Layers (see "What's in the image" in the README):
#   Base             ubuntu
#   Build toolchain  JDK + the Android SDK (everything below)
#   Convenience (DX) jq, lcov, yq
# The flutter image adds the Flutter layer on top.
FROM ubuntu:26.04@sha256:53958ec7b67c2c9355df922dd08dbf0360611f8c3cdb656875e81873db9ffdba

# OCI labels + annotations are workflow-owned (docker/metadata-action in build-image.yml),
# not baked here. See APPENDIX.md#oci-native-images.
USER root

ENV ANDROID_HOME=/opt/android-sdk-linux \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANGUAGE=en_US:en

ENV ANDROID_SDK_ROOT=$ANDROID_HOME \
    PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools:${ANDROID_HOME}/emulator

# comes from https://developer.android.com/studio/#command-line-tools-only
ENV ANDROID_SDK_TOOLS_VERSION=13114758

# --- Build toolchain: system packages --------------------------------------
# JDK + the deps to fetch and build with the Android SDK. jq and lcov are the
# Convenience (DX) tools (see "What's in the image" in the README).
RUN apt-get update \
    && apt-get install -y openjdk-21-jdk \
    && apt-get install -y sudo wget zip unzip git openssh-client curl build-essential libstdc++6 locales --no-install-recommends \
    # Convenience (DX): jq (JSON), lcov (coverage reports)
    && apt-get install -y jq lcov --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# JAVA_HOME for the JDK installed above. TARGETARCH (amd64/arm64) is set by Buildx and
# matches Ubuntu's /usr/lib/jvm/java-21-openjdk-<arch> layout; the "21" mirrors the
# openjdk-21-jdk pin above. Tools that read JAVA_HOME (Gradle, flutter doctor) then resolve
# the JDK deterministically instead of guessing via PATH.
ARG TARGETARCH
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-${TARGETARCH}

# --- Build toolchain: x86-64 runtime libs for emulated Android tools (arm64) -
# Google ships the Android Linux build tools (aapt2, zipalign, ...) as x86-64 ELF
# only, so on arm64 they run solely under host x86-64 emulation (Apple Silicon
# Docker/OrbStack: transparent; other arm64 Linux must register QEMU once with
# `docker run --privileged --rm tonistiigi/binfmt --install amd64`). This set is
# the empirical minimum the emulated tools load: libc6 + libgcc-s1 cover aapt2,
# zipalign, cmake and ninja; zlib1g (libz.so.1) is what the NDK clang needs for
# the default app's CMake step. libc++ is bundled in build-tools/lib64, and
# nothing links libstdc++.so.6. Emulated, NOT native Android; amd64 is
# unaffected. See ../../APPENDIX.md#arm64-android-build-limitation.
RUN if [ "$(uname -m)" = "aarch64" ]; then \
      set -eux; \
      codename="$(awk -F= '$1=="VERSION_CODENAME"{print $2}' /etc/os-release)"; \
      sed -i 's|^URIs: .*|&\nArchitectures: arm64|' /etc/apt/sources.list.d/ubuntu.sources; \
      printf 'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: %s %s-updates\nComponents: main universe\nArchitectures: amd64\nSigned-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg\n' "$codename" "$codename" > /etc/apt/sources.list.d/amd64.sources; \
      dpkg --add-architecture amd64; \
      apt-get update; \
      apt-get install -y --no-install-recommends libc6:amd64 libgcc-s1:amd64 zlib1g:amd64; \
      rm -rf /var/lib/apt/lists/*; \
    fi

# --- Build toolchain: locale -----------------------------------------------
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen \
    && locale-gen \
    && update-locale LANG=en_US.UTF-8

# --- Build toolchain: Android command-line tools ---------------------------
RUN cd /opt \
    && wget -q "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_TOOLS_VERSION}_latest.zip" -O android-sdk-tools.zip \
    && mkdir -p "${ANDROID_HOME}/cmdline-tools/" \
    && unzip -q android-sdk-tools.zip -d "${ANDROID_HOME}/cmdline-tools/" \
    && mv "${ANDROID_HOME}/cmdline-tools/cmdline-tools" "${ANDROID_HOME}/cmdline-tools/latest" \
    && chown -R root:root "$ANDROID_HOME" \
    && rm android-sdk-tools.zip

# --- Build toolchain: licenses + platform-tools ----------------------------
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers \
    && yes | sdkmanager --licenses \
    && mkdir -p /root/.android \
    && touch /root/.android/repositories.cfg \
    && sdkmanager platform-tools

# emulator is not available on linux/arm64 (https://issuetracker.google.com/issues/227219818)
RUN if [ "$(uname -m)" = "x86_64" ]; then sdkmanager emulator ; fi

# --- Build toolchain: Android platform + build-tools -----------------------
# https://developer.android.com/studio/releases/build-tools
ENV ANDROID_PLATFORM_VERSION=36
ENV ANDROID_BUILD_TOOLS_VERSION=36.0.0

RUN yes | sdkmanager \
    "platforms;android-$ANDROID_PLATFORM_VERSION" \
    "build-tools;$ANDROID_BUILD_TOOLS_VERSION"

# --- Convenience (DX): yq -----------------------------------------------------
# The jq for YAML, handy for poking at Flutter project config (pubspec.yaml,
# dependency_validator.yaml, slang, ...). Static Go binary from mikefarah/yq, arch-matched
# (its amd64/arm64 asset names are exactly Docker's TARGETARCH). Renovate-tracked (github-releases).
# renovate: datasource=github-releases depName=mikefarah/yq
ENV YQ_VERSION=v4.53.3
RUN wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" -O /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq
