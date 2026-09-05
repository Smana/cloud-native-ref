#!/bin/bash
set -e

# Configuration
#
# The version is READ from the Dockerfile's ARG, not copied here. CI
# (.github/workflows/build-container-images.yml) derives the published tag from
# `ARG OPENBAO_SNAPSHOT_VERSION=`, so a second literal in this file can only
# drift out of step with it -- and had: this file's literal was left behind by a
# Dockerfile bump, so a local build produced the new JWT-capable image and tagged
# it with the PREVIOUS version, silently disagreeing with what that tag means in
# the registry.
VERSION="$(sed -n 's/^ARG OPENBAO_SNAPSHOT_VERSION=\(.*\)$/\1/p' Dockerfile)"
if [ -z "${VERSION}" ]; then
  echo "error: no 'ARG OPENBAO_SNAPSHOT_VERSION=' in ./Dockerfile (run this from container-images/openbao-snapshot)" >&2
  exit 1
fi
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/smana}"
IMAGE_NAME="openbao-snapshot"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

echo "Building openbao-snapshot container image..."
echo "Image: ${FULL_IMAGE}"
echo ""

# Local build targets the host platform only (linux/amd64 on most dev
# machines) so the image loads straight into the local Docker daemon. CI
# builds linux/amd64 AND linux/arm64 via buildx (.github/workflows/build-container-images.yml)
# and pushes the multi-arch manifest; that step needs QEMU emulation and is
# not reproduced here.
docker build \
  --platform linux/amd64 \
  -t "${FULL_IMAGE}" \
  -t "${REGISTRY}/${IMAGE_NAME}:latest" \
  .

echo ""
echo "✅ Build successful!"
echo ""
echo "To push the image, run:"
echo "  docker push ${FULL_IMAGE}"
echo "  docker push ${REGISTRY}/${IMAGE_NAME}:latest"
echo ""
echo "To verify both CLIs are present:"
echo "  docker run --rm --entrypoint sh ${FULL_IMAGE} -c 'aws --version; gcloud --version | head -1; bao version; jq --version'"
