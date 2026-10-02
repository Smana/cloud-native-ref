#!/bin/bash
set -euo pipefail
# The version is READ from the Dockerfile's ARG, as CI does, so a local build
# can never tag itself differently from the registry.
cd "$(dirname "$0")"
VERSION="$(sed -n 's/^ARG AGENT_HARNESS_VERSION=\(.*\)$/\1/p' Dockerfile)"
[ -n "${VERSION}" ] || { echo "error: no 'ARG AGENT_HARNESS_VERSION=' in Dockerfile" >&2; exit 1; }
IMAGE="${CONTAINER_REGISTRY:-ghcr.io/smana}/agent-harness:${VERSION}"
docker build --target test .
docker build -t "${IMAGE}" .
echo "built ${IMAGE}"
