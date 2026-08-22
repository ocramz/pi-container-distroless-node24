# syntax=docker/dockerfile:1
#
# Pi coding agent on distroless Node 24.
#
# Distroless gives us glibc, OpenSSL, CA certificates and a Node 24 runtime --
# and deliberately nothing else. Pi is not self-contained: it spawns /bin/bash,
# ripgrep, fd, git and npm. So we assemble the smallest userland that makes
# those work (static busybox + real bash/git/rg/fd) in a builder stage and copy
# it onto distroless, keeping the property that matters: no package manager, no
# setuid binaries, non-root by default.
#
# All builder stages are bookworm-based, matching distroless-debian12's glibc.

ARG BUILDER=node:24-bookworm-slim@sha256:3638d9a6fe4030bd716be989438248074489337ba3275657f93595428be4fc03
ARG RUNTIME=gcr.io/distroless/nodejs24-debian12:nonroot@sha256:14d42e2511532589a7c7e01a753667a74fcc96266e137e8125006b87b0c32d0a
ARG PI_VERSION=0.84.2

# ---------------------------------------------------------------------------
# tools: the userland
# ---------------------------------------------------------------------------
# The runtime's filesystem, staged so the collector can tell which shared
# libraries distroless already ships and skip re-shipping them.
FROM ${RUNTIME} AS runtimefs

FROM ${BUILDER} AS tools

RUN apt-get update \
	&& apt-get install -y --no-install-recommends \
		bash \
		busybox-static \
		git \
		ripgrep \
		fd-find \
	&& rm -rf /var/lib/apt/lists/*

COPY --from=runtimefs / /runtime-base
COPY scripts/collect-rootfs.sh scripts/busybox-applets.txt /build/scripts/
RUN /build/scripts/collect-rootfs.sh /rootfs /runtime-base

# ---------------------------------------------------------------------------
# pi: the agent, npm and the TypeScript compiler
# ---------------------------------------------------------------------------
FROM ${BUILDER} AS pi

ARG PI_VERSION
ARG TYPESCRIPT_VERSION=5.9.3

# --ignore-scripts keeps the tree portable across the builder/runtime boundary.
# Pi has no native dependencies (its one binary-ish dep, photon-node, is wasm),
# so nothing needs to be compiled against this stage's Node.
RUN npm install --global --ignore-scripts --prefix /opt/pi \
		"@earendil-works/pi-coding-agent@${PI_VERSION}" \
		"typescript@${TYPESCRIPT_VERSION}" \
	&& rm -rf /opt/pi/bin /root/.npm

# Node 24's own bundled npm, so `pi install npm:...` and extension dependency
# installs work inside the image.
RUN cp -a /usr/local/lib/node_modules/npm /opt/npm

# Explicit wrappers rather than npm's generated `#!/usr/bin/env node` symlinks:
# they resolve node by absolute path and so survive any PATH the caller sets.
RUN mkdir -p /opt/pi/bin \
	&& printf '#!/bin/sh\nexec /nodejs/bin/node /opt/pi/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js "$@"\n' > /opt/pi/bin/pi \
	&& printf '#!/bin/sh\nexec /nodejs/bin/node /opt/npm/bin/npm-cli.js "$@"\n' > /opt/pi/bin/npm \
	&& printf '#!/bin/sh\nexec /nodejs/bin/node /opt/npm/bin/npx-cli.js "$@"\n' > /opt/pi/bin/npx \
	&& printf '#!/bin/sh\nexec /nodejs/bin/node /opt/pi/lib/node_modules/typescript/bin/tsc "$@"\n' > /opt/pi/bin/tsc \
	&& chmod 0755 /opt/pi/bin/* \
	&& chmod -R a+rX /opt

# ---------------------------------------------------------------------------
# runtime
# ---------------------------------------------------------------------------
FROM ${RUNTIME}

COPY --from=tools /rootfs /
# Explicit subpaths: the builder image keeps a bundled yarn in /opt that we do
# not want to inherit.
COPY --from=pi /opt/pi /opt/pi
COPY --from=pi /opt/npm /opt/npm
COPY --chmod=0644 extensions/container-env.ts /pi/agent/extensions/container-env.ts

# HOME is unset in the distroless base; without it os.homedir() has to fall back
# to /etc/passwd, which breaks under `--user <arbitrary-uid>`.
# /nodejs/bin is likewise not on the base PATH.
ENV HOME=/home/nonroot \
	PATH=/opt/pi/bin:/nodejs/bin:/usr/local/bin:/usr/bin:/bin \
	PI_CODING_AGENT_DIR=/pi/agent \
	PI_SKIP_VERSION_CHECK=1 \
	NPM_CONFIG_CACHE=/pi/npm-cache \
	NPM_CONFIG_UPDATE_NOTIFIER=false \
	GIT_PAGER=cat \
	PAGER=cat \
	TERM=xterm-256color

WORKDIR /workspace
USER 65532:65532

ARG PI_VERSION
ARG RUNTIME
ARG VCS_REF=unknown
ARG BUILD_DATE=unknown
LABEL org.opencontainers.image.title="pi-container-distroless-node24" \
	org.opencontainers.image.description="Pi coding agent on distroless Node 24" \
	org.opencontainers.image.source="https://github.com/ocramz/pi-container-distroless-node24" \
	org.opencontainers.image.licenses="MIT" \
	org.opencontainers.image.version="${PI_VERSION}" \
	org.opencontainers.image.revision="${VCS_REF}" \
	org.opencontainers.image.created="${BUILD_DATE}" \
	org.opencontainers.image.base.name="${RUNTIME}"

ENTRYPOINT ["/nodejs/bin/node", "/opt/pi/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js"]
