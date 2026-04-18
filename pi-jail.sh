#!/bin/bash

CONTAINER_NAME="pi-jail"
PI_PATH="/home/user/.pi"

HOST_PI_DIR="$HOME/.pi"

# Ensure the local directory exists so Docker doesn't create it as root
mkdir -p "$HOST_PI_DIR"

echo "Starting container '$CONTAINER_NAME' interactively with volume mounts..."
docker run -it --rm \
  --name "$CONTAINER_NAME" \
  --user 1000:1000 \
  -v "$HOST_PI_DIR:$PI_PATH" \
  -v "$(pwd):/workspace" \
  --add-host host.docker.internal=host-gateway \
  pi-jail
