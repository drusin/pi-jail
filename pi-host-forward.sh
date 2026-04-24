#!/usr/bin/env bash
set -euo pipefail

host="${PI_HOST_EXEC_HOST:-host.docker.internal}"
port="${PI_HOST_EXEC_PORT:-}"
token="${PI_HOST_EXEC_TOKEN:-}"
command="${1:-}"

if [ -z "${command}" ]; then
    echo "[pi-jail] Missing host command name" >&2
    exit 125
fi
shift || true

if [ -z "${port}" ]; then
    echo "[pi-jail] Host exec is not configured" >&2
    exit 125
fi

if [ -z "${token}" ]; then
    echo "[pi-jail] Missing host exec token" >&2
    exit 125
fi

host_exec_base64_encode() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

host_exec_base64_decode() {
    printf '%s' "$1" | tr -d '\r' | base64 -d
}

exec 3<>"/dev/tcp/${host}/${port}" || {
    echo "[pi-jail] Host exec connection failed" >&2
    exit 125
}

printf 'TOKEN %s\n' "$(host_exec_base64_encode "${token}")" >&3
printf 'COMMAND %s\n' "$(host_exec_base64_encode "${command}")" >&3
for arg in "$@"; do
    printf 'ARG %s\n' "$(host_exec_base64_encode "${arg}")" >&3
done
printf 'END\n' >&3

exit_code=""
while IFS= read -r line <&3; do
    [ -z "${line}" ] && continue

    type="${line%% *}"
    value=""
    if [ "${line}" != "${type}" ]; then
        value="${line#* }"
    fi

    case "${type}" in
        STDOUT)
            host_exec_base64_decode "${value}"
            ;;
        STDERR)
            host_exec_base64_decode "${value}" >&2
            ;;
        EXIT)
            exit_code="${value%%$'\r'}"
            break
            ;;
        *)
            echo "[pi-jail] Invalid host response: ${line}" >&2
            exec 3<&-
            exec 3>&-
            exit 125
            ;;
    esac
done

exec 3<&-
exec 3>&-

if [ -z "${exit_code}" ]; then
    echo "[pi-jail] Host exec connection closed before an exit code was received" >&2
    exit 125
fi

exit "${exit_code}"
