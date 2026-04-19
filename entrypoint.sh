#!/usr/bin/env bash
set -euo pipefail

# ── Configure git identity from env if provided ──────────────────────────────
if [ -n "${GIT_AUTHOR_NAME:-}" ]; then
    git config --global user.name "${GIT_AUTHOR_NAME}"
fi

if [ -n "${GIT_AUTHOR_EMAIL:-}" ]; then
    git config --global user.email "${GIT_AUTHOR_EMAIL}"
fi

exec "$@"
