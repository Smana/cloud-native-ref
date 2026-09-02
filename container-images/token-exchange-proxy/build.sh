#!/bin/bash
set -e

# Configuration
VERSION="v0.1.0"
REGISTRY="${CONTAINER_REGISTRY:-ghcr.io/smana}"
IMAGE_NAME="token-exchange-proxy"
FULL_IMAGE="${REGISTRY}/${IMAGE_NAME}:${VERSION}"

echo "Building token-exchange-proxy container image..."
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
echo "To verify the binary starts and rejects a request with no token:"
echo "  docker run --rm -e TEP_STS_URL=https://sts.example/token -e TEP_UPSTREAM_URL=http://127.0.0.1:1 -p 8080:8080 -d --name tep ${FULL_IMAGE}"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/healthz     # 200"
echo "  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/api/v1/x    # 401"
echo "  docker rm -f tep"
