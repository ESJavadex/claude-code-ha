# The official image is multi-arch: Docker selects amd64 or arm64 itself.
# Keep the base and OCI metadata here; build.yaml is deprecated by Supervisor.
FROM ghcr.io/home-assistant/base:3.24

# Install packages in a single layer to minimize image size
# Node.js and npm kept for image-service dependency. ttyd and tmux are baked in
# (they used to be apk-installed on every boot) so startup never needs the network.
# Install gh from Alpine too, so its build does not depend on GitHub API limits.
# apk upgrade first: the base image is only as fresh as its last publish, and
# Alpine ships security fixes as package revisions in between.
RUN apk upgrade --no-cache \
    && apk add --no-cache \
    nodejs \
    npm \
    bash \
    curl \
    nano \
    python3 \
    py3-pip \
    py3-requests \
    py3-aiohttp \
    py3-yaml \
    py3-beautifulsoup4 \
    jq \
    yq \
    git \
    github-cli \
    vim \
    wget \
    tree \
    tmux \
    ttyd

# Keep npm and pip caches out of /data so they never land in HA backups
# (HOME is /data/home at runtime, so npm's default ~/.npm would persist)
ENV npm_config_cache=/tmp/npm-cache \
    PIP_NO_CACHE_DIR=1

# Home Assistant Supervisor always passes BUILD_ARCH (amd64|aarch64) as a
# --build-arg. TARGETARCH is the automatic BuildKit value and only appears
# when building with `docker buildx --platform ...`; uname is the last resort.
# 32-bit ARM (armv7) was dropped in 2.3.9: Home Assistant no longer ships it.
ARG BUILD_ARCH
ARG TARGETARCH

RUN ADDON_ARCH="${BUILD_ARCH}"; \
    if [ -z "${ADDON_ARCH}" ]; then \
        case "${TARGETARCH}" in \
            amd64) ADDON_ARCH="amd64" ;; \
            arm64) ADDON_ARCH="aarch64" ;; \
        esac; \
    fi; \
    if [ -z "${ADDON_ARCH}" ]; then \
        case "$(uname -m)" in \
            x86_64)        ADDON_ARCH="amd64" ;; \
            aarch64|arm64) ADDON_ARCH="aarch64" ;; \
        esac; \
    fi; \
    case "${ADDON_ARCH}" in \
        amd64|aarch64) ;; \
        *) echo "Unsupported architecture (BUILD_ARCH='${BUILD_ARCH}' TARGETARCH='${TARGETARCH}' uname='$(uname -m)'): this add-on builds for amd64 and aarch64" && exit 1 ;; \
    esac; \
    printf '%s\n' "${ADDON_ARCH}" > /etc/addon-arch && \
    echo "Resolved add-on architecture: ${ADDON_ARCH} (BUILD_ARCH='${BUILD_ARCH}' TARGETARCH='${TARGETARCH}' uname='$(uname -m)')"

# Install Claude Code CLI: the native musl binary, fetched straight from the
# npm registry rather than by running https://claude.ai/install.sh, whose final
# `claude install` step is an interactive TUI that can hang a no-TTY build
# forever (ESJavadex/claude-code-ha#44) - and a hang never reaches a fallback.
# The npm package is only a wrapper that installs this same binary; it is kept
# as the fallback if the direct download fails. Approach adapted from
# heytcass/home-assistant-addons 2.5.1.
RUN set -o pipefail; \
    ADDON_ARCH=$(cat /etc/addon-arch); \
    case "${ADDON_ARCH}" in \
        amd64)   CLAUDE_PKG="linux-x64-musl" ;; \
        aarch64) CLAUDE_PKG="linux-arm64-musl" ;; \
        *)       CLAUDE_PKG="" ;; \
    esac; \
    if [ -n "${CLAUDE_PKG}" ] \
        && CLAUDE_VERSION=$(curl -fsSL --max-time 60 https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r .version) \
        && [ -n "${CLAUDE_VERSION}" ] && [ "${CLAUDE_VERSION}" != "null" ] \
        && mkdir -p /tmp/claude-pkg \
        && curl -fsSL --max-time 600 "https://registry.npmjs.org/@anthropic-ai/claude-code-${CLAUDE_PKG}/-/claude-code-${CLAUDE_PKG}-${CLAUDE_VERSION}.tgz" \
            | tar -xz -C /tmp/claude-pkg package/claude \
        && install -m 0755 /tmp/claude-pkg/package/claude /usr/local/bin/claude \
        && timeout 60 /usr/local/bin/claude --version; then \
        echo "Installed native Claude Code ${CLAUDE_VERSION} (${CLAUDE_PKG})"; \
    else \
        echo "Direct native download failed; falling back to npm install"; \
        rm -f /usr/local/bin/claude; \
        npm install -g @anthropic-ai/claude-code; \
    fi; \
    rm -rf /tmp/claude-pkg; \
    if [ ! -x /usr/local/bin/claude ]; then \
        echo "Claude Code install failed (direct download and npm)" >&2; exit 1; \
    fi

# Install Home Assistant CLI (ha command), latest release
RUN ADDON_ARCH=$(cat /etc/addon-arch); \
    case "${ADDON_ARCH}" in \
        amd64)   HA_ARCH="amd64";   HA_VERSION="latest" ;; \
        aarch64) HA_ARCH="aarch64"; HA_VERSION="latest" ;; \
        *)       echo "Unsupported architecture: ${ADDON_ARCH}" && exit 1 ;; \
    esac && \
    if [ "${HA_VERSION}" = "latest" ]; then \
        echo "Fetching latest Home Assistant CLI version..."; \
        HA_VERSION=$(curl -fsSL https://api.github.com/repos/home-assistant/cli/releases/latest | jq -r '.tag_name'); \
    fi && \
    echo "Installing Home Assistant CLI ${HA_VERSION} for ${HA_ARCH}..." && \
    curl -fsSL -o /usr/bin/ha \
        "https://github.com/home-assistant/cli/releases/download/${HA_VERSION}/ha_${HA_ARCH}" && \
    chmod +x /usr/bin/ha && \
    echo "Home Assistant CLI ${HA_VERSION} installed successfully"

# Home Assistant plugin for Claude Code (current HA syntax, YAML checks after
# every edit). Pinned to a release tag of ESJavadex/claude-homeassistant-plugins
# and installed from this local copy on first start (setup_ha_plugin in run.sh),
# so startup never needs the network. Bump the tag to ship a newer plugin.
ARG HA_PLUGINS_REF=v2.1.4
RUN git clone --quiet --depth 1 --branch "${HA_PLUGINS_REF}" \
        https://github.com/ESJavadex/claude-homeassistant-plugins.git \
        /opt/claude-plugins/claude-homeassistant-plugins \
    && cd /opt/claude-plugins/claude-homeassistant-plugins \
    && rm -rf .git .github homeassistant-config/tests \
    && jq -e '.version' homeassistant-config/.claude-plugin/plugin.json

# Create directory for Claude configuration and set working directory
RUN mkdir -p /config/claude-config
WORKDIR /config

# Copy and install image service
COPY image-service/ /opt/image-service/
RUN cd /opt/image-service \
    && npm install --production --no-optional \
    && npm cache clean --force \
    && chmod +x server.mjs

# Copy startup script and modular scripts
COPY run.sh /run.sh
COPY scripts/ /opt/scripts/
COPY .claude/ /opt/.claude/
RUN chmod +x /run.sh \
    && chmod +x /opt/scripts/*.sh

# Supervisor supplies config.yaml's version; CI does the same. A local build
# without release arguments is explicitly marked as a development image.
ARG BUILD_VERSION=dev
LABEL org.opencontainers.image.title="Claude Terminal Pro" \
    org.opencontainers.image.description="Claude Code terminal for Home Assistant with persistent auth, packages and file uploads" \
    org.opencontainers.image.source="https://github.com/ESJavadex/claude-code-ha" \
    org.opencontainers.image.licenses="MIT" \
    org.opencontainers.image.version="${BUILD_VERSION}"

# Use exec form for better signal handling
CMD ["/run.sh"]
