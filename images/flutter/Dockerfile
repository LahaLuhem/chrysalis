FROM ghcr.io/lahaluhem/android-sdk:latest

LABEL org.opencontainers.image.source=https://github.com/LahaLuhem/chrysalis \
      org.opencontainers.image.description="Flutter on the chrysalis android-sdk base image"

USER root

ARG flutter_version

ENV FLUTTER_HOME=/opt/flutter \
    FLUTTER_VERSION=$flutter_version
ENV FLUTTER_ROOT=$FLUTTER_HOME

ENV PATH=${PATH}:${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin

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
