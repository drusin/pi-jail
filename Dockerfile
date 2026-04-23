# syntax=docker/dockerfile:1

# ── Version args (override at build time if needed) ──────────────────────────
ARG NODE_VERSION=24
ARG JAVA_VERSION=25

# ── Node.js LTS base ─────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-bookworm-slim

# ── Re-declare after FROM (build args don't cross FROM boundaries) ────────────
ARG JAVA_VERSION

# ── System deps + Temurin JDK ────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        curl \
        git \
        ca-certificates \
        gnupg \
        openssh-client \
        bash \
        dos2unix \
        maven \
    && rm -rf /var/lib/apt/lists/*

RUN wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public \
        | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] \
        https://packages.adoptium.net/artifactory/deb bookworm main" \
        > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends temurin-${JAVA_VERSION}-jdk \
    && rm -rf /var/lib/apt/lists/*

# ── Create user 1000:1000 ────────────────────────────────────────────────────
RUN usermod  -l user  node \
    && groupmod -n user node \
    && usermod  -d /home/user -m user \
    && mkdir -p /home/user/.pi /home/user/.m2 /workspace \
    && chown -R user:user /home/user /workspace

# ── pi coding agent (installed as root, available globally) ─────────────────
RUN npm install -g @mariozechner/pi-coding-agent

# ── Entrypoint ───────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN dos2unix /entrypoint.sh && chmod +x /entrypoint.sh

USER user
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]
