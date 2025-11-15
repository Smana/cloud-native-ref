#!/bin/bash
set -e

# Configuration
VERSION="v1.17.0"
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/smana}"
IMAGE_NAME="pev2"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

echo "Building PEV2 container image..."
echo "Image: ${FULL_IMAGE}"
echo ""

# Build the image
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
echo "To test locally:"
echo "  docker run --rm -p 8080:8080 ${FULL_IMAGE}"
echo "  Open http://localhost:8080"
