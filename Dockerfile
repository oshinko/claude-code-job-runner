FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION=2.1.220
ARG CONTAINER_UID=10001
ARG CONTAINER_GID=10001

ENV DISABLE_AUTOUPDATER=1 \
    CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
    CLAUDE_CONFIG_DIR=/tmp/claude-code-config

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        git \
        tini \
    && rm -rf /var/lib/apt/lists/* \
    && npm install --global "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
    && npm cache clean --force \
    && groupadd --gid "${CONTAINER_GID}" runner \
    && useradd --uid "${CONTAINER_UID}" --gid "${CONTAINER_GID}" --create-home --shell /bin/bash runner \
    && mkdir -p /workspace /tmp/claude-code-config \
    && chown -R runner:runner /workspace /tmp/claude-code-config

COPY --chown=root:root docker-entrypoint.sh /usr/local/bin/claude-code-job-runner
RUN chmod 0755 /usr/local/bin/claude-code-job-runner

USER runner
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/claude-code-job-runner"]
