#!/usr/bin/env bash
set -euo pipefail

# ── Configure git identity from env if provided ──────────────────────────────
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
    git config --global user.name "${GIT_AUTHOR_NAME}"
fi

if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
    git config --global user.email "${GIT_AUTHOR_EMAIL}"
fi

# ── Mark /workspace and its immediate subdirectories as safe for git ──────────────
if [ -d /workspace ]; then
    while IFS= read -r dir; do
        git config --global --add safe.directory "${dir}"
    done < <(find /workspace -maxdepth 1 -type d)
fi

# ── Optional host-command shims ──────────────────────────────────────────────
if [ -n "${RUN_ON_HOST:-}" ] && [ -n "${PI_HOST_EXEC_TOKEN:-}" ]; then
    if [ -n "${PI_HOST_EXEC_SOCKET:-}" ] || [ -n "${PI_HOST_EXEC_PORT:-}" ]; then
        shim_dir="${HOME:-/home/user}/.local/share/pi-host-shims"
        mkdir -p "${shim_dir}"

        IFS=',' read -r -a host_commands <<< "${RUN_ON_HOST}"
        for command in "${host_commands[@]}"; do
            command="$(printf '%s' "${command}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
            [ -z "${command}" ] && continue

            if [[ ! "${command}" =~ ^[A-Za-z0-9_.-]+$ ]]; then
                echo "[pi-jail] Warning: ignoring invalid RUN_ON_HOST command '${command}'" >&2
                continue
            fi

            cat > "${shim_dir}/${command}" <<EOF
#!/usr/bin/env bash
exec /usr/local/lib/pi-host-forward.sh "${command}" "\$@"
EOF
            chmod +x "${shim_dir}/${command}"
        done

        export PATH="${shim_dir}:${PATH}"
    fi
fi

# ── Default to pi and pass through CLI args ──────────────────────────────────
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- pi "$@"
fi

exec "$@"
