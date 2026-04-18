#!/bin/bash

CONTAINER_NAME="pi-jail"
PI_PATH="/home/user/.pi"
HOST_PI_DIR="$HOME/.pi"

# 1. Get the name of the current directory (e.g., "my-awesome-project")
PROJECT_NAME=$(basename "$(pwd)")

# 2. Define the target path inside the container
TARGET_WORKSPACE="/workspace/$PROJECT_NAME"

# Ensure local config directory exists
mkdir -p "$HOST_PI_DIR"

echo "Starting '$CONTAINER_NAME' for project '$PROJECT_NAME'..."

docker run -it --rm \
  --name "$CONTAINER_NAME" \
  --user 1000:1000 \
  -v "$HOST_PI_DIR:$PI_PATH" \
  -v "$(pwd):$TARGET_WORKSPACE" \
  --add-host host.docker.internal=host-gateway \
  -w "$TARGET_WORKSPACE" \
  pi-jail
