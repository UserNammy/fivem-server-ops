# syntax=docker/dockerfile:1.7
#
# FXServer (FiveM) image.
#
# The Cfx.re server artifacts are NOT stored in this repository and are NOT
# redistributed: they are downloaded from the official Cfx.re artifact server
# at build time. Pin the exact build you validated with --build-arg.
#
#   docker build \
#     --build-arg ARTIFACT_BUILD=<build>-<commit sha> \
#     --build-arg ARTIFACT_SHA256=<sha256 of fx.tar.xz> \
#     -f docker/Dockerfile -t fivem-server-ops/fxserver:<build> .
#
# The build context is the repository root (the template lives in server-data/).
#
# ARTIFACT_BUILD is the folder name listed on
# https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master/
# (format "NNNNN-<40 hex chars>").

############################
# Stage 1: fetch artifacts #
############################
FROM debian:bookworm-slim AS fetch

ARG ARTIFACT_BUILD
ARG ARTIFACT_SHA256=""
ARG ARTIFACT_BASE_URL=https://runtime.fivem.net/artifacts/fivem/build_proot_linux/master

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Debian package versions are not pinned on purpose: pinned versions disappear
# from the mirrors after security updates and break the build.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl xz-utils \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /opt/fxserver

RUN if [[ -z "${ARTIFACT_BUILD}" ]]; then \
      echo "ERROR: ARTIFACT_BUILD build-arg is required (e.g. NNNNN-<sha1>)." >&2; exit 1; \
    fi \
 && curl -fsSL --retry 3 -o /tmp/fx.tar.xz "${ARTIFACT_BASE_URL}/${ARTIFACT_BUILD}/fx.tar.xz" \
 && if [[ -n "${ARTIFACT_SHA256}" ]]; then \
      echo "${ARTIFACT_SHA256}  /tmp/fx.tar.xz" | sha256sum -c -; \
    else \
      echo "WARNING: ARTIFACT_SHA256 not set, skipping checksum verification." >&2; \
    fi \
 && tar -xJf /tmp/fx.tar.xz -C /opt/fxserver \
 && rm /tmp/fx.tar.xz \
 && test -x /opt/fxserver/run.sh

########################
# Stage 2: runtime     #
########################
FROM debian:bookworm-slim

ARG ARTIFACT_BUILD
ARG FIVEM_UID=1000
ARG FIVEM_GID=1000

LABEL org.opencontainers.image.title="fxserver" \
      org.opencontainers.image.description="FiveM FXServer runtime (artifacts fetched at build time, not redistributed)" \
      org.opencontainers.image.licenses="MIT" \
      io.fivem.artifact-build="${ARTIFACT_BUILD}"

# gettext-base -> envsubst (server.cfg templating)
# tini         -> proper PID 1, forwards SIGTERM so FXServer shuts down cleanly
# curl         -> healthcheck
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl gettext-base tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid "${FIVEM_GID}" fivem \
 && useradd --uid "${FIVEM_UID}" --gid fivem --home-dir /srv/fivem --shell /usr/sbin/nologin fivem \
 && mkdir -p /srv/fivem/server-data/resources /srv/fivem/txData /srv/fivem/config \
 && chown -R fivem:fivem /srv/fivem

COPY --from=fetch --chown=root:root /opt/fxserver /opt/fxserver
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 docker/healthcheck.sh /usr/local/bin/healthcheck.sh
COPY --chmod=0644 server-data/server.cfg.template /opt/fivem/server.cfg.template

ENV FXSERVER_DIR=/opt/fxserver \
    SERVER_DATA_DIR=/srv/fivem/server-data \
    TXADMIN_ENABLED=false \
    TXHOST_DATA_PATH=/srv/fivem/txData \
    TXHOST_TXA_PORT=40120 \
    FIVEM_PORT=30120

USER fivem
WORKDIR /srv/fivem/server-data

# Game traffic (TCP + UDP) and txAdmin web panel
EXPOSE 30120/tcp 30120/udp 40120/tcp

VOLUME ["/srv/fivem/server-data", "/srv/fivem/txData"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=120s --retries=3 \
  CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
