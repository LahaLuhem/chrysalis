FROM ghcr.io/lahaluhem/android-sdk:latest

LABEL org.opencontainers.image.source=https://github.com/LahaLuhem/chrysalis \
      org.opencontainers.image.description="Flutter on the chrysalis android-sdk base image"

USER root

ARG flutter_version

ENV FLUTTER_HOME=/opt/flutter \
    FLUTTER_VERSION=$flutter_version
ENV FLUTTER_ROOT=$FLUTTER_HOME

# `dart pub global activate` installs tool executables under PUB_CACHE; its bin/ on PATH makes
# them bare commands. /root/.pub-cache is Dart's default for root; set explicitly for clarity.
ENV PUB_CACHE=/root/.pub-cache
ENV PATH=${PATH}:${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin:${PUB_CACHE}/bin

# Quiet CI defaults (override with `-e BOT=false`): FLUTTER_SUPPRESS_ANALYTICS no-ops Flutter analytics; BOT=true trips flutter+dart bot detection,
# which no-ops Dart analytics and skips Flutter's version-freshness check.
# Rationale, including why not CI=true: ../../APPENDIX.md#quiet-ci-defaults
# BOT is an internal flutter_tools lever, not a documented one:
# https://github.com/flutter/flutter/blob/stable/packages/flutter_tools/lib/src/base/bot_detector.dart
ENV FLUTTER_SUPPRESS_ANALYTICS=true \
    BOT=true

RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git ${FLUTTER_HOME}

RUN yes | flutter doctor --android-licenses \
    && flutter doctor \
    && chown -R root:root ${FLUTTER_HOME}

RUN flutter precache --android

# --- Flutter DX tooling: native CLIs on PATH (DX only, not needed to build) ---
# cider: version bumps + CHANGELOG. dependency_validator: flags missing/unused/mis-promoted deps.
# Compiled to self-contained native executables, NOT `dart pub global activate`: activation leaves an
# SDK-version-keyed snapshot (.../cider.dart-<sdk>.snapshot), so a shared or persisted PUB_CACHE that
# outlives an SDK bump serves a stale snapshot and the tool breaks until re-activated. Native binaries
# in /usr/local/bin don't touch PUB_CACHE and survive SDK upgrades. Why: ../../APPENDIX.md#dx-tools-native
# Pinned exact and Renovate-bumped (dart custom manager in ../../.github/renovate.jsonc), like YQ_VERSION.
# renovate: datasource=dart depName=cider
ENV CIDER_VERSION=0.2.10
# renovate: datasource=dart depName=dependency_validator
ENV DEPENDENCY_VALIDATOR_VERSION=5.0.5
# Activate (resolve + download + generate package_config), compile the resolved entrypoint to a native
# binary, then deactivate and drop the cache artifacts so the snapshot/sources don't ship in the image.
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
