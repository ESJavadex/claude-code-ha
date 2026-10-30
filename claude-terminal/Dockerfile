ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install packages in a single layer to minimize image size
# Node.js and npm kept for image-service dependency. ttyd and tmux are baked in
# (they used to be apk-installed on every boot) so startup never needs the network.
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

# Install GitHub CLI (gh command), latest release
RUN ADDON_ARCH=$(cat /etc/addon-arch); \
    case "${ADDON_ARCH}" in \
        amd64)   GH_ARCH="amd64"; GH_VERSION="latest" ;; \
        aarch64) GH_ARCH="arm64"; GH_VERSION="latest" ;; \
        *)       echo "Unsupported architecture for gh: ${ADDON_ARCH}" && exit 1 ;; \
    esac && \
    if [ "${GH_VERSION}" = "latest" ]; then \
        echo "Fetching latest GitHub CLI version..."; \
        GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name' | sed 's/^v//'); \
    fi && \
    echo "Installing GitHub CLI v${GH_VERSION} for ${GH_ARCH}..." && \
    curl -fsSL -o /tmp/gh.tar.gz \
        "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${GH_ARCH}.tar.gz" && \
    tar -xzf /tmp/gh.tar.gz -C /tmp && \
    mv /tmp/gh_${GH_VERSION}_linux_${GH_ARCH}/bin/gh /usr/bin/gh && \
    chmod +x /usr/bin/gh && \
    rm -rf /tmp/gh* && \
    echo "GitHub CLI v${GH_VERSION} installed successfully"

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

# Use exec form for better signal handling
CMD ["/run.sh"]
