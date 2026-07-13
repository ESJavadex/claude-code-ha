ARG BUILD_FROM
FROM ${BUILD_FROM}

# Install packages in a single layer to minimize image size
# Node.js and npm kept for image-service dependency
RUN apk add --no-cache \
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
    tree

# Home Assistant Supervisor always passes BUILD_ARCH (amd64|aarch64|armv7|armhf|i386)
# as a --build-arg. TARGETARCH/TARGETVARIANT are the automatic BuildKit values and
# only appear when building with `docker buildx --platform ...`. IMPORTANT: BuildKit
# never sets TARGETARCH to "arm/v7" — for 32-bit ARM it is "arm" with TARGETVARIANT
# "v7". Relying on TARGETARCH="arm/v7" silently breaks every ARMv7 build, so we
# resolve a single canonical arch from the most reliable source available.
ARG BUILD_ARCH
ARG TARGETARCH
ARG TARGETVARIANT

RUN ADDON_ARCH="${BUILD_ARCH}"; \
    if [ -z "${ADDON_ARCH}" ]; then \
        case "${TARGETARCH}/${TARGETVARIANT}" in \
            amd64/*)      ADDON_ARCH="amd64" ;; \
            arm64/*)      ADDON_ARCH="aarch64" ;; \
            arm/v7)       ADDON_ARCH="armv7" ;; \
            arm/v6)       ADDON_ARCH="armhf" ;; \
            arm/)         ADDON_ARCH="armv7" ;; \
            386/*)        ADDON_ARCH="i386" ;; \
        esac; \
    fi; \
    if [ -z "${ADDON_ARCH}" ]; then \
        case "$(uname -m)" in \
            x86_64)        ADDON_ARCH="amd64" ;; \
            aarch64|arm64) ADDON_ARCH="aarch64" ;; \
            armv7l)        ADDON_ARCH="armv7" ;; \
            armv6l)        ADDON_ARCH="armhf" ;; \
            i386|i686)     ADDON_ARCH="i386" ;; \
        esac; \
    fi; \
    if [ -z "${ADDON_ARCH}" ]; then \
        echo "Cannot determine target architecture (BUILD_ARCH='${BUILD_ARCH}' TARGETARCH='${TARGETARCH}' TARGETVARIANT='${TARGETVARIANT}' uname='$(uname -m)')" && exit 1; \
    fi; \
    printf '%s\n' "${ADDON_ARCH}" > /etc/addon-arch && \
    echo "Resolved add-on architecture: ${ADDON_ARCH} (BUILD_ARCH='${BUILD_ARCH}' TARGETARCH='${TARGETARCH}/${TARGETVARIANT}' uname='$(uname -m)')"

# Install Claude Code CLI. Current native releases do not publish a 32-bit ARM
# binary, so armv7/armhf use the final portable 1.x JavaScript release. Supported
# 64-bit targets keep the native-latest path with the existing npm fallback.
RUN ADDON_ARCH=$(cat /etc/addon-arch); \
    if [ "${ADDON_ARCH}" = "armv7" ] || [ "${ADDON_ARCH}" = "armhf" ]; then \
        echo "32-bit ARM (${ADDON_ARCH}): installing portable Claude Code 1.0.128"; \
        npm install -g @anthropic-ai/claude-code@1.0.128; \
    else \
        (curl -fsSL https://claude.ai/install.sh | bash \
        && ln -sf /root/.local/bin/claude /usr/local/bin/claude) \
        || npm install -g @anthropic-ai/claude-code; \
    fi

# Install Home Assistant CLI (ha command)
# 64-bit targets track latest; 4.46.0 is the last release that still ships the
# ha_armv7 / ha_armhf / ha_i386 assets (latest dropped them and would 404).
RUN ADDON_ARCH=$(cat /etc/addon-arch); \
    case "${ADDON_ARCH}" in \
        amd64)   HA_ARCH="amd64";   HA_VERSION="latest" ;; \
        aarch64) HA_ARCH="aarch64"; HA_VERSION="latest" ;; \
        armv7)   HA_ARCH="armv7";   HA_VERSION="4.46.0" ;; \
        armhf)   HA_ARCH="armhf";   HA_VERSION="4.46.0" ;; \
        i386)    HA_ARCH="i386";    HA_VERSION="4.46.0" ;; \
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

# Install GitHub CLI (gh command)
# 32-bit ARM has no upstream armv7 build; the armv6 binary runs on armv7. gh is
# pinned to the last release verified to publish linux_armv6 so a future upstream
# drop cannot break 32-bit builds without a deliberate bump here.
RUN ADDON_ARCH=$(cat /etc/addon-arch); \
    case "${ADDON_ARCH}" in \
        amd64)   GH_ARCH="amd64"; GH_VERSION="latest" ;; \
        aarch64) GH_ARCH="arm64"; GH_VERSION="latest" ;; \
        armv7)   GH_ARCH="armv6"; GH_VERSION="2.96.0" ;; \
        armhf)   GH_ARCH="armv6"; GH_VERSION="2.96.0" ;; \
        i386)    GH_ARCH="386";   GH_VERSION="latest" ;; \
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
    && chmod +x server.js

# Copy startup script and modular scripts
COPY run.sh /run.sh
COPY scripts/ /opt/scripts/
COPY .claude/ /opt/.claude/
RUN chmod +x /run.sh \
    && chmod +x /opt/scripts/*.sh

# Use exec form for better signal handling
CMD ["/run.sh"]
