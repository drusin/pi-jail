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

# ── Parse command line arguments ─────────────────────────────────────────────
NO_WORKSPACE=false
filtered_args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-workspace)
            NO_WORKSPACE=true
            shift
            ;;
        *)
            filtered_args+=("$1")
            shift
            ;;
    esac
done
set -- "${filtered_args[@]}"

# ── Resolve workspace: mount current folder under /workspace/<dirname> ───────
WORKSPACE="${PWD}"
FOLDER_NAME="$(basename "${WORKSPACE}")"
if [ "${NO_WORKSPACE}" = "true" ]; then
    CONTAINER_WORKDIR="/home/user"
else
    CONTAINER_WORKDIR="/workspace/${FOLDER_NAME}"
fi
CONTAINER_SUFFIX="$(printf '%s' "${FOLDER_NAME}" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9_.-]+/-/g; s/^-+//; s/-+$//')"
CONTAINER_SUFFIX="${CONTAINER_SUFFIX:-workspace}"
CONTAINER_NAME="pi-jail-${CONTAINER_SUFFIX}"

if docker container inspect "${CONTAINER_NAME}" &>/dev/null; then
    CONTAINER_RUNNING="$(docker container inspect --format '{{.State.Running}}' "${CONTAINER_NAME}")"
    if [ "${CONTAINER_RUNNING}" = "true" ]; then
        echo "[pi-jail] Error: container '${CONTAINER_NAME}' is already running." >&2
        exit 1
    fi

    echo "[pi-jail] Removing stopped container '${CONTAINER_NAME}'..."
    docker rm "${CONTAINER_NAME}" >/dev/null
fi

# ── Ensure ~/.pi exists on host and is owned by current user ─────────────────
PI_DIR="${HOME}/.pi"
mkdir -p "${PI_DIR}"

# ── Match container user to current host user (helps git ownership checks) ──
LOCAL_UID="$(id -u)"
LOCAL_GID="$(id -g)"

# ── Run ──────────────────────────────────────────────────────────────────────
docker_args=(
    run
    --rm
    -it
    --name "${CONTAINER_NAME}"
    --user "${LOCAL_UID}:${LOCAL_GID}"
    --add-host host.docker.internal=host-gateway
)
if [ "${NO_WORKSPACE}" = "false" ]; then
    docker_args+=(-v "${WORKSPACE}:${CONTAINER_WORKDIR}")
fi
docker_args+=(
    -v "${PI_DIR}:/home/user/.pi"
    -w "${CONTAINER_WORKDIR}"
)

if [ -f "${ENV_FILE}" ]; then
    docker_args+=(--env-file "${ENV_FILE}")
fi

echo "[pi-jail] Starting pi in: ${CONTAINER_WORKDIR}"
docker "${docker_args[@]}" "${IMAGE_NAME}" pi "$@"
