# syntax=docker/dockerfile:1
FROM ubuntu:24.04

LABEL maintainer="Claude Code Container"
LABEL description="Isolated container for running Claude Code in YOLO mode on .NET/Vue.js/Vite projects"

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=fr_BE.UTF-8
ENV LC_ALL=fr_BE.UTF-8

# ---------- 1. System packages ----------
ARG LAZYGIT_VERSION=0.44.1
ARG DELTA_VERSION=0.19.2
ARG YQ_VERSION=4.52.5
# Bootstrap: install prerequisites needed to add external repos
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends \
    apt-utils ca-certificates curl gnupg
# Add external repos then install all packages
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    gpg --keyserver keyserver.ubuntu.com --recv-keys 23F3D4EA75716059 \
    && gpg --export 23F3D4EA75716059 > /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get update && apt-get install -y --no-install-recommends \
    git \
    wget \
    jq \
    ripgrep \
    unzip \
    sudo \
    python3 \
    python3-pip \
    python3-venv \
    build-essential \
    apt-transport-https \
    software-properties-common \
    locales \
    fd-find \
    bat \
    tree \
    fzf \
    shellcheck \
    httpie \
    gosu \
    gh \
    nodejs \
    sqlite3 \
    && locale-gen en_US.UTF-8 \
    && locale-gen fr_BE.UTF-8 \
    && ln -sf /usr/bin/fdfind /usr/local/bin/fd \
    && ln -sf /usr/bin/batcat /usr/local/bin/bat \
    && curl -Lo /tmp/lazygit.tar.gz \
        "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" \
    && tar xf /tmp/lazygit.tar.gz -C /tmp lazygit \
    && install /tmp/lazygit /usr/local/bin/ \
    && rm /tmp/lazygit.tar.gz /tmp/lazygit \
    && curl -Lo /tmp/delta.deb \
        "https://github.com/dandavison/delta/releases/download/${DELTA_VERSION}/git-delta_${DELTA_VERSION}_amd64.deb" \
    && dpkg -i /tmp/delta.deb \
    && rm /tmp/delta.deb \
    && curl -Lo /usr/local/bin/yq \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
    && chmod +x /usr/local/bin/yq

# ---------- 1a. Chromium for browser automation (optional, skip with --build-arg INSTALL_CHROMIUM=false) ----------
ARG INSTALL_CHROMIUM=true
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    if [ "$INSTALL_CHROMIUM" = "true" ]; then \
        apt-get update && apt-get install -y --no-install-recommends \
            chromium \
            fonts-liberation \
            libgbm1 \
            libnss3 \
            libatk-bridge2.0-0 \
            libx11-xcb1 \
            libxcomposite1 \
            libxdamage1 \
            libxrandr2 \
            libcups2 \
            libpango-1.0-0 \
            libcairo2; \
    fi
ENV CHROME_PATH=/usr/bin/chromium

# ---------- 2. Node.js global packages ----------
RUN --mount=type=cache,target=/root/.npm \
    npm install -g yarn pnpm

# ---------- 3. .NET SDK (base LTS + install script kept for runtime detection) ----------
RUN curl -fsSL https://dot.net/v1/dotnet-install.sh -o /usr/local/bin/dotnet-install.sh \
    && chmod +x /usr/local/bin/dotnet-install.sh \
    && /usr/local/bin/dotnet-install.sh --channel LTS --install-dir /usr/share/dotnet \
    && ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1
ENV DOTNET_NOLOGO=1

# ---------- 4. Non-root user ----------
RUN userdel -r ubuntu 2>/dev/null || true \
    && groupdel ubuntu 2>/dev/null || true \
    && useradd -m -U -s /bin/bash -u 1000 claude \
    && echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude \
    && chmod 0440 /etc/sudoers.d/claude \
    && mkdir -p /project \
    && chown claude:claude /project

# Set npm global prefix to user-writable location (MCP servers, yarn, pnpm, dev tools)
ENV NPM_CONFIG_PREFIX=/home/claude/.npm-global
ENV PATH=/home/claude/.npm-global/bin:/home/claude/.dotnet/tools:$PATH

# ---------- 5. Claude Code CLI (native installer) ----------
# `latest` channel (vs default `stable`) so the image ships with the newest release;
# `claude update` at startup then keeps it current. User prefs already set autoUpdatesChannel=latest.
USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash -s latest \
    && mkdir -p /home/claude/.claude

# ---------- 5a. .NET global tools ----------
RUN dotnet tool install --global dotnet-ef

# ---------- 5b. uv (Python package runner for Python-based MCP servers) ----------
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/home/claude/.local/bin:$PATH"

# Pre-cache Python MCP servers so uvx doesn't download at runtime
# Version pinned for reproducible builds (update: see https://pypi.org/project/mcp-server-fetch/)
ARG MCP_FETCH_VERSION=2025.4.7
RUN uvx --from "mcp-server-fetch==${MCP_FETCH_VERSION}" mcp-server-fetch --help > /dev/null 2>&1 || true

# ---------- 5c. GitHub MCP Server (Go binary, replaces deprecated npm package) ----------
# Version pinned (update: see https://github.com/github/github-mcp-server/releases)
ARG GITHUB_MCP_VERSION=v1.0.0
USER root
RUN RELEASE_URL=$(curl -fsSL "https://api.github.com/repos/github/github-mcp-server/releases/tags/${GITHUB_MCP_VERSION}" | \
    jq -r '.assets[].browser_download_url' | grep -i 'linux.*x86_64' | head -1) && \
    if [ -n "$RELEASE_URL" ]; then \
        curl -fsSL -o /tmp/github-mcp.tar.gz "$RELEASE_URL" && \
        tar xzf /tmp/github-mcp.tar.gz -C /tmp && \
        find /tmp -maxdepth 2 -name 'github-mcp-server' -type f -exec cp {} /usr/local/bin/ \; && \
        chmod +x /usr/local/bin/github-mcp-server && \
        rm -f /tmp/github-mcp.tar.gz && \
        echo "GitHub MCP server ${GITHUB_MCP_VERSION} installed"; \
    else \
        echo "WARNING: GitHub MCP server ${GITHUB_MCP_VERSION} not found, will use deprecated npm package"; \
    fi
USER claude

# ---------- 5d. MCP servers + dev tools (Node.js) ----------
# Versions pinned for reproducible builds (update: npm view <pkg> version)
ARG MCP_FILESYSTEM_VERSION=2026.1.14
ARG MCP_MEMORY_VERSION=2026.1.26
ARG MCP_SEQUENTIAL_THINKING_VERSION=2025.12.18
ARG MCP_GITHUB_VERSION=2025.4.8
ARG MCP_BRAVE_SEARCH_VERSION=2.0.76
ARG MCP_PLAYWRIGHT_VERSION=0.0.70
ARG MCP_CONTEXT7_VERSION=2.1.8
ARG MCP_DBHUB_VERSION=0.21.2
ARG MCP_DOCKER_VERSION=1.0.0
ARG TYPESCRIPT_VERSION=6.0.3
ARG ESLINT_VERSION=10.2.1
ARG PRETTIER_VERSION=3.8.3
ARG VUE_TSC_VERSION=3.2.7
ARG NPM_CHECK_UPDATES_VERSION=21.0.2
RUN --mount=type=cache,target=/home/claude/.npm,uid=1000,gid=1000 \
    npm install -g \
    "@modelcontextprotocol/server-filesystem@${MCP_FILESYSTEM_VERSION}" \
    "@modelcontextprotocol/server-memory@${MCP_MEMORY_VERSION}" \
    "@modelcontextprotocol/server-sequential-thinking@${MCP_SEQUENTIAL_THINKING_VERSION}" \
    "@modelcontextprotocol/server-github@${MCP_GITHUB_VERSION}" \
    "@brave/brave-search-mcp-server@${MCP_BRAVE_SEARCH_VERSION}" \
    "@playwright/mcp@${MCP_PLAYWRIGHT_VERSION}" \
    "@upstash/context7-mcp@${MCP_CONTEXT7_VERSION}" \
    "@bytebase/dbhub@${MCP_DBHUB_VERSION}" \
    "mcp-server-docker@${MCP_DOCKER_VERSION}" \
    "typescript@${TYPESCRIPT_VERSION}" \
    "eslint@${ESLINT_VERSION}" \
    "prettier@${PRETTIER_VERSION}" \
    "vue-tsc@${VUE_TSC_VERSION}" \
    "npm-check-updates@${NPM_CHECK_UPDATES_VERSION}"

# ---------- 6. Git config ----------
RUN git config --global user.name "Claude Code" \
    && git config --global user.email "claude@container.local" \
    && git config --global --add safe.directory /project \
    && git config --global init.defaultBranch main

# ---------- 7. Prepare .claude directories ----------
RUN mkdir -p /home/claude/.claude/skills \
    /home/claude/.claude/projects \
    /home/claude/.claude/sessions \
    /home/claude/.claude/plans \
    /home/claude/.claude/hooks \
    /home/claude/.claude/container-hooks \
    /home/claude/.claude/mcp-memory

# ---------- 8. Hook: protect sensitive files (stored outside mounted hooks dir) ----------
COPY --chown=claude:claude container/protect-config.sh /home/claude/.claude/container-hooks/protect-config.sh
RUN chmod +x /home/claude/.claude/container-hooks/protect-config.sh

# ---------- 8a. Statusline script ----------
COPY --chown=claude:claude container/statusline.sh /home/claude/.claude/statusline.sh
RUN chmod +x /home/claude/.claude/statusline.sh

# ---------- 8b. Claude session wrapper (saves prefs on exit) ----------
COPY --chown=claude:claude container/claude-session.sh /usr/local/bin/claude-session
RUN chmod +x /usr/local/bin/claude-session

# ---------- 8c. Dynamic .NET SDK installer ----------
USER root
COPY container/install-dotnet.sh /usr/local/bin/install-dotnet.sh
COPY container/install-dotnet-sdk.sh /usr/local/bin/install-dotnet-sdk.sh
RUN chmod +x /usr/local/bin/install-dotnet.sh /usr/local/bin/install-dotnet-sdk.sh

# ---------- 9. Entrypoint (runs as root, drops to claude via gosu) ----------
COPY --chown=claude:claude container/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Strip CRLF from scripts (Windows git may checkout with \r)
RUN sed -i 's/\r$//' \
    /usr/local/bin/entrypoint.sh \
    /usr/local/bin/claude-session \
    /usr/local/bin/install-dotnet.sh \
    /usr/local/bin/install-dotnet-sdk.sh \
    /home/claude/.claude/container-hooks/protect-config.sh \
    /home/claude/.claude/statusline.sh

WORKDIR /project
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["--dangerously-skip-permissions"]
