# Android SDK image: Ubuntu + cmdline-tools, platform-tools, build-tools, a platform.
# This is the base layer the flutter image builds FROM. The SDK build tools are
# x86-64-only on Linux. See ../../APPENDIX.md#arm64-android-build-limitation.
#
# Layers (see "What's in the image" in the README):
#   Base             ubuntu
#   Build toolchain  JDK + the Android SDK (everything below)
#   Convenience (DX) jq, lcov, yq
# The flutter image adds the Flutter layer on top.
FROM ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7

# OCI labels + annotations are workflow-owned (docker/metadata-action in build-image.yml),
# not baked here. See APPENDIX.md#oci-native-images.

ENV ANDROID_HOME=/opt/android-sdk-linux \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    LANGUAGE=en_US:en

ENV ANDROID_SDK_ROOT=$ANDROID_HOME \
    PATH=${PATH}:${ANDROID_HOME}/cmdline-tools/latest/bin:${ANDROID_HOME}/platform-tools

# comes from https://developer.android.com/studio/#command-line-tools-only
# Opaque build number, this one is rev 22. Held there: rev 23 routes every install through an
# x86-64-only launcher the native arm64 build can't run (APPENDIX.md#no-android-cli).
# check-android-sdk.sh owns the hold and re-checks its way out.
ENV ANDROID_SDK_TOOLS_VERSION=15859902

# --- Build toolchain: system packages --------------------------------------
# Headless JDK: Android/Gradle builds need no GUI libs (AWT runs headless), and the full
# JDK's recommends add ~500 MB. No build-essential: the NDK bundles its own toolchain,
# so nothing here invokes host gcc/make.
RUN apt-get update \
    && apt-get install -y openjdk-21-jdk-headless --no-install-recommends \
    # openssl signs the OAuth2 JWT for the ch-fetch-firebase-config helper (which also uses curl + jq)
    && apt-get install -y sudo wget zip unzip git openssh-client curl openssl libstdc++6 locales --no-install-recommends \
    # Convenience (DX): jq (JSON), lcov (coverage reports)
    && apt-get install -y jq lcov --no-install-recommends \
    && rm -rf /var/lib/apt/lists/*

# So Gradle and flutter doctor find the JDK without guessing from PATH.
# TARGETARCH matches Ubuntu's java-21-openjdk-<arch> dirs, and the 21 has to match the JDK package above.
ARG TARGETARCH
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-${TARGETARCH}

# --- Build toolchain: x86-64 runtime libs for emulated Android tools (arm64) -
# Google ships the Android build tools as x86-64 only, so arm64 runs them under the host's emulation.
# These are the x86-64 libs they load. ../../APPENDIX.md#arm64-android-build-limitation
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
    # x86-64 only, and flutter_tools would pick it just because it's there. APPENDIX.md#no-android-cli
    && rm "${ANDROID_HOME}/cmdline-tools/latest/bin/android" \
    && chown -R root:root "$ANDROID_HOME" \
    && rm android-sdk-tools.zip

# --- Build toolchain: licenses + platform-tools ----------------------------
# sdkmanager, because the `android` CLI is dropped above (APPENDIX.md#no-android-cli).
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers \
    && yes | sdkmanager --licenses \
    && mkdir -p /root/.android \
    && touch /root/.android/repositories.cfg \
    && sdkmanager platform-tools

# --- Build toolchain: Android platform + build-tools -----------------------
# https://developer.android.com/studio/releases/build-tools
ENV ANDROID_PLATFORM_VERSION=36
ENV ANDROID_BUILD_TOOLS_VERSION=36.0.0

RUN yes | sdkmanager \
    "platforms;android-$ANDROID_PLATFORM_VERSION" \
    "build-tools;$ANDROID_BUILD_TOOLS_VERSION"

# --- Convenience (DX): yq -----------------------------------------------------
# The jq for YAML, handy for Flutter project config (pubspec.yaml, slang, ...).
# yq names its release assets by arch exactly like TARGETARCH, so one URL fits both.
# renovate: datasource=github-releases depName=mikefarah/yq
ENV YQ_VERSION=v4.54.1
RUN wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" -O /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq
