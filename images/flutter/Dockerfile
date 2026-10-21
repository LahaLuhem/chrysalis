# CI passes a digest here, so both arch builds share one base. The tag default keeps a plain
# `docker build` working. ../../APPENDIX.md#pinned-base
ARG base_ref=ghcr.io/lahaluhem/android-sdk:latest
FROM ${base_ref}

# OCI labels + annotations are workflow-owned (docker/metadata-action in build-image.yml),
# not baked here. See APPENDIX.md#oci-native-images.

ARG flutter_version

ENV FLUTTER_HOME=/opt/flutter \
    FLUTTER_VERSION=$flutter_version
ENV FLUTTER_ROOT=$FLUTTER_HOME

# `dart pub global activate` installs tool executables under PUB_CACHE, and its bin/ on PATH
# makes them bare commands. /root/.pub-cache is Dart's default for root, set here for clarity.
ENV PUB_CACHE=/root/.pub-cache
ENV PATH=${PATH}:${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PUB_CACHE}/bin

# Quiet CI defaults: analytics off and no version-freshness check. Override with `-e BOT=false`.
# BOT is an undocumented flutter_tools switch. ../../APPENDIX.md#quiet-ci-defaults
ENV FLUTTER_SUPPRESS_ANALYTICS=true \
    BOT=true

RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git ${FLUTTER_HOME}

# Why --no-same-owner: APPENDIX.md#root-owned-sdk
# No --android-licenses: the base image already accepted the full set (APPENDIX.md#no-android-cli).
RUN export TAR_OPTIONS=--no-same-owner \
    && flutter doctor \
    && flutter precache --android

# --- Flutter DX tooling: native CLIs on PATH (DX only, not needed to build) ---
# cider bumps versions and the CHANGELOG, dependency_validator flags missing, unused or misplaced deps.
# Compiled to native binaries, since an activated tool breaks once its PUB_CACHE outlives an SDK bump.
# ../../APPENDIX.md#dx-tools-native
# renovate: datasource=dart depName=cider
ENV CIDER_VERSION=0.2.10
# renovate: datasource=dart depName=dependency_validator
ENV DEPENDENCY_VALIDATOR_VERSION=5.1.0
# Activate only to fetch and resolve, then compile, and drop the cache so no snapshot or source ships.
RUN set -eux; \
    dart pub global activate cider "$CIDER_VERSION"; \
    dart pub global activate dependency_validator "$DEPENDENCY_VALIDATOR_VERSION"; \
    dart compile exe "$PUB_CACHE/hosted/pub.dev/cider-$CIDER_VERSION/bin/cider.dart" \
      --packages "$PUB_CACHE/global_packages/cider/.dart_tool/package_config.json" \
      -o /usr/local/bin/cider; \
    dart compile exe "$PUB_CACHE/hosted/pub.dev/dependency_validator-$DEPENDENCY_VALIDATOR_VERSION/bin/dependency_validator.dart" \
      --packages "$PUB_CACHE/global_packages/dependency_validator/.dart_tool/package_config.json" \
      -o /usr/local/bin/dependency_validator; \
    dart pub global deactivate cider; \
    dart pub global deactivate dependency_validator; \
    rm -rf "${PUB_CACHE:?}/global_packages" "${PUB_CACHE:?}/bin" "${PUB_CACHE:?}/hosted"

# --- Build-env setup helpers (DX only, not needed to build) ---
# Each does nothing until a job calls it. ../../APPENDIX.md#build-setup-android
# Copying the whole dir means a new helper needs no edit here. --chmod covers a lost exec bit.
COPY --chmod=0755 scripts/ /usr/local/bin/

# Paths the helpers write, relative to the project root.
# Baked as ENV so the helpers and the build job read one value. ../../APPENDIX.md#build-setup-android
ENV CH_BUILD_DART_DEFINE_FILE=lib/env/dart_defines.env \
    CH_BUILD_CACHE_KEYSTORE=android/app/ch-signing.p12

# Cache hints for the user's build job. Nothing in the image reads them.
# Narrow on purpose: all of ~/.gradle would drag in daemon logs and lock files too.
# GRADLE_USER_HOME is pinned to its default so both paths resolve the same every run.
# See ../../APPENDIX.md#build-setup-android.
ENV GRADLE_USER_HOME=/root/.gradle
ENV CH_BUILD_CACHE_GRADLE_MODULES=${GRADLE_USER_HOME}/caches/modules-2 \
    CH_BUILD_CACHE_GRADLE_DISTS=${GRADLE_USER_HOME}/wrapper/dists

# The NDK isn't baked (../../APPENDIX.md#ndk-cmake-not-baked), so a cold build pulls ~690 MiB of it.
# Cache all of this dir or none of it: a half-restored one isn't repaired, it fails the build.
# Fixed path, ANDROID_NDK_ROOT won't move it (flutter_tools only looks under ANDROID_HOME).
ENV CH_BUILD_CACHE_NDK=${ANDROID_HOME}/ndk
