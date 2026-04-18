# --- Version Configuration ---
ARG NODE_VERSION=24
# -----------------------------

FROM node:${NODE_VERSION}

# Set environment variables
ENV DEBIAN_FRONTEND=noninteractive

# Install necessary tools and the pi agent globally
# We do this as root before switching users
RUN npm install -g @mariozechner/pi-coding-agent

# Set up the "user" with UID/GID 1000:1000
# We delete the default 'node' user first to ensure UID 1000 is available
RUN userdel -r node || true && \
    groupadd --gid 1000 user && \
    useradd --uid 1000 --gid user --shell /bin/bash --create-home user

# Prepare the workspace and set ownership
RUN mkdir -p /workspace && chown user:user /workspace

# Set the working directory
WORKDIR /workspace

# Switch to the non-root user
USER user

# Set the entrypoint
ENTRYPOINT ["pi"]
