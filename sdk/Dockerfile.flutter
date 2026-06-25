FROM ghcr.io/lahaluhem/android-sdk:latest

LABEL org.opencontainers.image.source=https://github.com/LahaLuhem/chrysalis \
      org.opencontainers.image.description="Flutter on the chrysalis android-sdk base image"

USER root

ARG flutter_version

ENV FLUTTER_HOME=/opt/flutter \
    FLUTTER_VERSION=$flutter_version
ENV FLUTTER_ROOT=$FLUTTER_HOME

ENV PATH=${PATH}:${FLUTTER_HOME}/bin:${FLUTTER_HOME}/bin/cache/dart-sdk/bin

RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git ${FLUTTER_HOME}

RUN yes | flutter doctor --android-licenses \
    && flutter doctor \
    && chown -R root:root ${FLUTTER_HOME}

RUN flutter precache --android
