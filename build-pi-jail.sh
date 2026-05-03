#!/usr/bin/env bash
set -euo pipefail

PI_PACKAGE="@mariozechner/pi-coding-agent"
DRY_RUN=false

for arg in "$@"; do
    case "$arg" in
        --dry) DRY_RUN=true ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "🔍 Querying npm for latest version of ${PI_PACKAGE}..."

VERSION=$(curl -sS "https://registry.npmjs.org/${PI_PACKAGE}/latest" \
    | grep -o '"version":"[^"]*"' \
    | cut -d'"' -f4)

if [ -z "$VERSION" ]; then
    echo "❌ Failed to retrieve latest version from npm registry."
    exit 1
fi

echo "✅ Latest version: ${VERSION}"
echo ""

DOCKER_CMD=(docker build --build-arg "PI_VERSION=${VERSION}" -t pi-jail .)

if [ "$DRY_RUN" = true ]; then
    echo "🏗️  Dry run — would execute:"
    echo ""
    echo "    ${DOCKER_CMD[*]}"
else
    echo "🏗️  Building pi-jail image with pi-coding-agent@${VERSION}..."
    echo ""
    "${DOCKER_CMD[@]}"
    echo ""
    echo "✅ Done! Image 'pi-jail' built with pi-coding-agent@${VERSION}."
fi
