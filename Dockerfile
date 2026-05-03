# syntax=docker/dockerfile:1

# ── Version args (override at build time if needed) ──────────────────────────
ARG NODE_VERSION=24
ARG PI_VERSION=latest

# ── Node.js LTS base ─────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-bookworm-slim

# ── Re-declare after FROM (build args don't cross FROM boundaries) ────────────
ARG PI_VERSION

# ── System deps + PowerShell 7 ──────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        wget \
        curl \
        git \
        ca-certificates \
        gnupg \
        openssh-client \
        bash \
        dos2unix \
        python3 \
        python-is-python3 \
    && rm -rf /var/lib/apt/lists/*

# Install PowerShell 7 (Microsoft repo)
RUN wget -qO - https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/microsoft.gpg] \
        https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/microsoft.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends powershell \
    && rm -rf /var/lib/apt/lists/*

# ── Create user 1000:1000 ────────────────────────────────────────────────────
RUN usermod  -l user  node \
    && groupmod -n user node \
    && usermod  -d /home/user -m user \
    && mkdir -p /home/user/.pi /workspace \
    && chown -R user:user /home/user /workspace

# ── pi coding agent (installed as root, available globally) ─────────────────
RUN npm install -g @mariozechner/pi-coding-agent@${PI_VERSION}

# ── Entrypoint + host-forwarding helper ─────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
COPY pi-host-forward.sh /usr/local/lib/pi-host-forward.sh
RUN dos2unix /entrypoint.sh /usr/local/lib/pi-host-forward.sh \
    && chmod +x /entrypoint.sh /usr/local/lib/pi-host-forward.sh

USER user
WORKDIR /workspace

ENTRYPOINT ["/entrypoint.sh"]
CMD ["pi"]
