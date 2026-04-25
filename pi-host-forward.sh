#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
shift || true

if [ -z "${command}" ]; then
    echo "[pi-jail] Missing host command name" >&2
    exit 125
fi

token="${PI_HOST_EXEC_TOKEN:-}"
if [ -z "${token}" ]; then
    echo "[pi-jail] Missing host exec token" >&2
    exit 125
fi

host_exec_base64_encode() {
    printf '%s' "$1" | base64 | tr -d '\n'
}

# Build the request text
request=""
request+="TOKEN $(host_exec_base64_encode "${token}")"$'\n'
request+="COMMAND $(host_exec_base64_encode "${command}")"$'\n'
for arg in "$@"; do
    request+="ARG $(host_exec_base64_encode "${arg}")"$'\n'
done
request+="END"$'\n'

socket_path="${PI_HOST_EXEC_SOCKET:-}"
if [ -n "${socket_path}" ]; then
    # Unix domain socket via Python (available in the container image)
    export PI_HOST_EXEC_REQUEST="${request}"
    export PI_HOST_EXEC_SOCKET="${socket_path}"
    python3 -c '
import base64, os, socket, sys

request = os.environ["PI_HOST_EXEC_REQUEST"]
socket_path = os.environ["PI_HOST_EXEC_SOCKET"]

def decode_value(value):
    value = value.strip()
    if not value:
        return b""
    try:
        return base64.b64decode(value)
    except Exception:
        return b""

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(socket_path)
    sock.sendall(request.encode("utf-8"))
    sock.shutdown(socket.SHUT_WR)

    buf = b""
    while True:
        data = sock.recv(8192)
        if not data:
            break
        buf += data
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            line = line.decode("utf-8", errors="replace").strip()
            if not line:
                continue

            parts = line.split(" ", 1)
            frame_type = parts[0]
            value = parts[1] if len(parts) > 1 else ""

            if frame_type == "STDOUT":
                sys.stdout.buffer.write(decode_value(value))
                sys.stdout.flush()
            elif frame_type == "STDERR":
                sys.stderr.buffer.write(decode_value(value))
                sys.stderr.flush()
            elif frame_type == "EXIT":
                code_str = value.strip()
                exit_code = int(code_str) if code_str else 125
                sys.exit(exit_code)
            else:
                print(f"[pi-jail] Invalid host response: {line}", file=sys.stderr)
                sys.exit(125)

    print("[pi-jail] Host exec connection closed before an exit code was received", file=sys.stderr)
    sys.exit(125)
except SystemExit:
    raise
except Exception as e:
    print(f"[pi-jail] Host exec connection failed: {e}", file=sys.stderr)
    sys.exit(125)
'
else
    # TCP via bash /dev/tcp/ (Windows / Docker Desktop path)
    host="${PI_HOST_EXEC_HOST:-host.docker.internal}"
    port="${PI_HOST_EXEC_PORT:-}"

    if [ -z "${port}" ]; then
        echo "[pi-jail] Host exec is not configured" >&2
        exit 125
    fi

    exec 3<>"/dev/tcp/${host}/${port}" || {
        echo "[pi-jail] Host exec connection failed" >&2
        exit 125
    }

    printf '%s' "${request}" >&3

    host_exec_base64_decode() {
        printf '%s' "$1" | tr -d '\r' | base64 -d
    }

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
fi
