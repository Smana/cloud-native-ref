#!/bin/bash
set -e

# Configuration — keep VERSION in step with ARG HEADLAMP_PLUGIN_APP_VERSION in
# the Dockerfile; CI derives the published semver tag from the ARG.
VERSION="v0.1.0"
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/smana}"
IMAGE_NAME="headlamp-plugin-app"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

echo "Building ${FULL_IMAGE}..."

# Local build targets the host platform only; CI builds amd64 + arm64 via
# buildx and pushes the multi-arch manifest.
docker build --platform linux/amd64 -t "${FULL_IMAGE}" -t "${REGISTRY}/${IMAGE_NAME}:latest" .

echo ""
echo "✅ Build successful."
echo ""
echo "To verify the image carries the plugin:"
echo "  docker run --rm ${FULL_IMAGE} ls -l /plugins/headlamp-plugin-app/"
echo "  # expect main.js and package.json"
