#!/usr/bin/env bash
set -euo pipefail

DOCKER_USER="bahn1075"
REPO="park-reserve"
ARCH=$(uname -m | sed 's/x86_64/amd64/')
TAG=$(date '+%y%m%d%H%M')
IMAGE="${DOCKER_USER}/${REPO}:${TAG}"
IMAGE_ARCH="${DOCKER_USER}/${REPO}:${ARCH}"
IMAGE_LATEST="${DOCKER_USER}/${REPO}:latest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Build: ${IMAGE} ==="
docker build -t "${IMAGE}" -t "${IMAGE_ARCH}" -t "${IMAGE_LATEST}" "${SCRIPT_DIR}"

echo "=== Push: ${IMAGE} ==="
docker push "${IMAGE}"

echo "=== Push: ${IMAGE_ARCH} ==="
docker push "${IMAGE_ARCH}"

echo "=== Push: ${IMAGE_LATEST} ==="
docker push "${IMAGE_LATEST}"

echo "=== Done: ${IMAGE} / ${IMAGE_ARCH} ==="
