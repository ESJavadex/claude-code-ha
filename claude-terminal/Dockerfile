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

ARG TARGETARCH

# Install Claude Code CLI. Current native releases do not publish an ARMv7
# binary, so ARMv7 uses the final portable 1.x JavaScript release. Supported
# 64-bit targets keep the native-latest path with the existing npm fallback.
RUN if [ "${TARGETARCH}" = "arm/v7" ]; then \
        npm install -g @anthropic-ai/claude-code@1.0.128; \
    else \
        (curl -fsSL https://claude.ai/install.sh | bash \
        && ln -sf /root/.local/bin/claude /usr/local/bin/claude) \
        || npm install -g @anthropic-ai/claude-code; \
    fi

# Install Home Assistant CLI (ha command)
# Download appropriate binary based on build architecture
# Automatically fetches the latest version from GitHub
RUN case "${TARGETARCH}" in \
        amd64)   HA_ARCH="amd64"; HA_VERSION="latest" ;; \
        arm64)   HA_ARCH="aarch64"; HA_VERSION="latest" ;; \
        arm/v7)  HA_ARCH="armv7"; HA_VERSION="4.46.0" ;; \
        arm/v6)  HA_ARCH="armhf"; HA_VERSION="4.46.0" ;; \
        386)     HA_ARCH="i386"; HA_VERSION="4.46.0" ;; \
        *)       echo "Unsupported architecture: ${TARGETARCH}" && exit 1 ;; \
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
# Download appropriate binary based on build architecture
RUN case "${TARGETARCH}" in \
        amd64)   GH_ARCH="amd64" ;; \
        arm64)   GH_ARCH="arm64" ;; \
        arm/v7)  GH_ARCH="armv6" ;; \
        386)     GH_ARCH="386" ;; \
        *)       echo "Unsupported architecture for gh: ${TARGETARCH}" && exit 1 ;; \
    esac && \
    echo "Fetching latest GitHub CLI version..." && \
    GH_VERSION=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r '.tag_name' | sed 's/^v//') && \
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
