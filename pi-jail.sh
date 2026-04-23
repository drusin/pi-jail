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
PORT_SPECS=()
RANDOM_PORT_REQUESTS=0
filtered_args=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --no-workspace)
            NO_WORKSPACE=true
            shift
            ;;
        -p)
            if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
                PORT_SPECS+=("$2")
                shift 2
            else
                RANDOM_PORT_REQUESTS=$((RANDOM_PORT_REQUESTS + 1))
                shift
            fi
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

get_env_value() {
    local key="$1"
    local line
    local value=""

    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        if [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            break
        fi
    done < "${ENV_FILE}"

    printf '%s' "$(printf '%s' "${value}" | sed -E "s/^[[:space:]]+//; s/[[:space:]]+$//; s/^\"(.*)\"$/\1/; s/^'(.*)'$/\1/")"
}

resolve_host_path() {
    local path="$1"

    case "${path}" in
        "~")
            path="${HOME}"
            ;;
        ~/*)
            path="${HOME}/${path#~/}"
            ;;
    esac

    printf '%s' "${path}"
}

is_port_free() {
    local port="$1"

    if command -v ss >/dev/null 2>&1; then
        ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
        return
    fi

    if command -v lsof >/dev/null 2>&1; then
        ! lsof -nP -iTCP:"${port}" -sTCP:LISTEN >/dev/null 2>&1
        return
    fi

    if command -v netstat >/dev/null 2>&1; then
        ! netstat -ltn 2>/dev/null | awk 'NR > 2 { print $4 }' | grep -Eq "(^|[:.])${port}$"
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 - "${port}" <<'PY'
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("0.0.0.0", port))
except OSError:
    raise SystemExit(1)
else:
    raise SystemExit(0)
finally:
    sock.close()
PY
        return
    fi

    return 2
}

array_contains() {
    local needle="$1"
    shift

    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done

    return 1
}

find_next_free_port() {
    local port
    local status

    for ((port = 9000; port <= 65535; port++)); do
        if array_contains "${port}" "${seen_ports[@]}"; then
            continue
        fi

        if is_port_free "${port}"; then
            printf '%s\n' "${port}"
            return 0
        fi

        status=$?
        if [ "${status}" -eq 2 ]; then
            return 2
        fi
    done

    return 1
}

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

    ports_raw="$(get_env_value PORTS)"
    if [ -n "${ports_raw}" ]; then
        PORT_SPECS+=("${ports_raw}")
    fi

    random_port_value="$(get_env_value RANDOM_PORT)"
    if [[ "${random_port_value,,}" = "true" ]]; then
        RANDOM_PORT_REQUESTS=$((RANDOM_PORT_REQUESTS + 1))
    fi

    mvn_settings_xml="$(resolve_host_path "$(get_env_value MVN_SETTINGS_XML)")"
    if [ -n "${mvn_settings_xml}" ]; then
        if [ -f "${mvn_settings_xml}" ]; then
            docker_args+=(-v "${mvn_settings_xml}:/home/user/.m2/settings.xml:ro")
        else
            echo "[pi-jail] Warning: MVN_SETTINGS_XML file not found: ${mvn_settings_xml}" >&2
        fi
    fi

    node_npmrc="$(resolve_host_path "$(get_env_value NODE_NPMRC)")"
    if [ -n "${node_npmrc}" ]; then
        if [ -f "${node_npmrc}" ]; then
            docker_args+=(-v "${node_npmrc}:/home/user/.npmrc:ro")
        else
            echo "[pi-jail] Warning: NODE_NPMRC file not found: ${node_npmrc}" >&2
        fi
    fi
fi

seen_ports=()
busy_ports=()
unchecked_ports=()
bound_ports=()
random_port_failures=0
random_port_unchecked=0

if [ ${#PORT_SPECS[@]} -gt 0 ]; then
    for port_spec in "${PORT_SPECS[@]}"; do
        IFS=',' read -r -a ports <<< "${port_spec}"
        for port in "${ports[@]}"; do
            port="$(printf '%s' "${port}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            [ -z "${port}" ] && continue

            if [[ ! "${port}" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
                echo "[pi-jail] Warning: ignoring invalid port '${port}'" >&2
                continue
            fi

            if array_contains "${port}" "${seen_ports[@]}"; then
                continue
            fi
            seen_ports+=("${port}")

            if is_port_free "${port}"; then
                docker_args+=(-p "${port}:${port}")
                bound_ports+=("${port}")
                continue
            fi

            case $? in
                1)
                    busy_ports+=("${port}")
                    ;;
                2)
                    unchecked_ports+=("${port}")
                    ;;
            esac
        done
    done
fi

if [ "${RANDOM_PORT_REQUESTS}" -gt 0 ]; then
    for ((i = 0; i < RANDOM_PORT_REQUESTS; i++)); do
        if random_port="$(find_next_free_port)"; then
            seen_ports+=("${random_port}")
            docker_args+=(-p "${random_port}:${random_port}")
            bound_ports+=("${random_port}")
            continue
        fi

        case $? in
            1)
                random_port_failures=$((random_port_failures + 1))
                ;;
            2)
                random_port_unchecked=$((random_port_unchecked + 1))
                ;;
        esac
    done
fi

if [ ${#busy_ports[@]} -gt 0 ]; then
    echo "[pi-jail] Warning: not binding ports already in use: ${busy_ports[*]}" >&2
fi
if [ ${#unchecked_ports[@]} -gt 0 ]; then
    echo "[pi-jail] Warning: not binding ports because availability could not be checked: ${unchecked_ports[*]}" >&2
fi
if [ "${random_port_failures}" -gt 0 ]; then
    echo "[pi-jail] Warning: could not find ${random_port_failures} free random port(s) starting at 9000" >&2
fi
if [ "${random_port_unchecked}" -gt 0 ]; then
    echo "[pi-jail] Warning: could not allocate ${random_port_unchecked} random port(s) because availability could not be checked" >&2
fi

EXPOSED_PORTS=""
if [ ${#bound_ports[@]} -gt 0 ]; then
    EXPOSED_PORTS="$(IFS=,; echo "${bound_ports[*]}")"
fi
docker_args+=(-e "EXPOSED_PORTS=${EXPOSED_PORTS}")

echo "[pi-jail] Starting pi in: ${CONTAINER_WORKDIR}"
docker "${docker_args[@]}" "${IMAGE_NAME}" pi "$@"
