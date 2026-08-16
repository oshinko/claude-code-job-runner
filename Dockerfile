FROM node:24-trixie-slim

ARG CLAUDE_CODE_VERSION=2.1.233
ARG CONTAINER_UID=10001
ARG CONTAINER_GID=10001

ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    CLAUDE_CONFIG_DIR=/tmp/claude-code-config \
    PATH=/home/runner/.local/bin:${PATH} \
    XDG_CACHE_HOME=/home/runner/.cache \
    PIP_CACHE_DIR=/home/runner/.cache/pip \
    npm_config_cache=/home/runner/.cache/npm \
    UV_CACHE_DIR=/home/runner/.cache/uv

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        build-essential \
        curl \
        git \
        jq \
        python-is-python3 \
        python3-pip \
        python3-venv \
        ripgrep \
        tini \
        unzip \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid "${CONTAINER_GID}" runner \
    && useradd --uid "${CONTAINER_UID}" --gid "${CONTAINER_GID}" --create-home --shell /bin/bash runner \
    && mkdir -p /workspace /tmp/claude-code-config /home/runner/.cache \
    && chown -R runner:runner /workspace /tmp/claude-code-config /home/runner/.cache

COPY --chown=root:root docker-entrypoint.sh /usr/local/bin/claude-code-job-runner
RUN chmod 0755 /usr/local/bin/claude-code-job-runner

USER runner
WORKDIR /workspace

RUN curl -fsSL https://claude.ai/install.sh -o /tmp/install-claude.sh \
    && bash /tmp/install-claude.sh "${CLAUDE_CODE_VERSION}" \
    && rm -f /tmp/install-claude.sh \
    && claude --version

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/claude-code-job-runner"]
