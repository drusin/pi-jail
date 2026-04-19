#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_NAME="pi-jail"
ENV_FILE="${SCRIPT_DIR}/pi-jail.env"

# ── Build image if not present ───────────────────────────────────────────────
if ! docker image inspect "${IMAGE_NAME}" &>/dev/null; then
    echo "[pi-jail] Building image '${IMAGE_NAME}'..."
    docker build -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
fi

# ── Resolve workspace: mount current folder under /workspace/<dirname> ───────
WORKSPACE="${PWD}"
FOLDER_NAME="$(basename "${WORKSPACE}")"
CONTAINER_WORKDIR="/workspace/${FOLDER_NAME}"

# ── Ensure ~/.pi exists on host and is owned by current user ─────────────────
PI_DIR="${HOME}/.pi"
mkdir -p "${PI_DIR}"

# ── Run ──────────────────────────────────────────────────────────────────────
echo "[pi-jail] Starting pi in: ${CONTAINER_WORKDIR}"
docker run \
    --rm \
    -it \
    --name "pi-jail-$(date +%s)" \
    --user 1000:1000 \
    --add-host host.docker.internal=host-gateway \
    -v "${WORKSPACE}:${CONTAINER_WORKDIR}" \
    -v "${PI_DIR}:/home/user/.pi" \
    -w "${CONTAINER_WORKDIR}" \
    $([ -f "${ENV_FILE}" ] && echo "--env-file ${ENV_FILE}" || echo "") \
    "${IMAGE_NAME}" \
    "$@"
