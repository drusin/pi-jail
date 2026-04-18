#!/bin/bash

CONTAINER_NAME="pi-jail"
SETTING_PATH="/root/.pi/agent"

# Check if the necessary files exist before attempting to run the container
if [ ! -f "models.json" ] || [ ! -f "settings.json" ]; then
    echo "Error: models.json and settings.json must exist in the current directory to mount them."
    exit 1
fi

echo "Starting container '$CONTAINER_NAME' interactively with volume mounts..."
docker run -it --rm \
  --name "$CONTAINER_NAME" \
  -v "$(pwd)/models.json:$SETTING_PATH/models.json" \
  -v "$(pwd)/settings.json:$SETTING_PATH/settings.json" \
  -v "$(pwd)":/workspace \
  --add-host host.docker.internal=host-gateway \
  pi-jail
