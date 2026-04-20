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

# ── Default to pi and pass through CLI args ──────────────────────────────────
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- pi "$@"
fi

exec "$@"
