#!/usr/bin/env bash
set -euo pipefail

# helm-update 이미지를 멀티아치(amd64+arm64)로 빌드하고 push 한다.
# 단일 아치 `docker build`는 빌더 아키텍처로만 :latest를 덮어써서(예: amd64 머신 →
# :latest=amd64) arm64 클러스터(OKE)에서 ImagePullBackOff가 났다. buildx로 매니페스트
# 리스트를 push해 아키텍처 무관하게 pull 되도록 한다.
#
# 태그: latest + 날짜(YYMMDDHHMM) — 둘 다 멀티아치 매니페스트 리스트.

DOCKER_USER="bahn1075"
REPO="helm-update"
TAG=$(date '+%y%m%d%H%M')
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
BUILDER="${BUILDER:-cozy-multiarch}"

IMAGE="${DOCKER_USER}/${REPO}:${TAG}"
IMAGE_LATEST="${DOCKER_USER}/${REPO}:latest"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 크로스아치 에뮬레이션(qemu binfmt) 준비 — 네이티브가 아닌 플랫폼을 빌드하려면 필요.
# 이미 등록돼 있으면 건너뛴다(멱등). Docker Desktop/OrbStack은 보통 기본 포함.
if [ -d /proc/sys/fs/binfmt_misc ] && ! ls /proc/sys/fs/binfmt_misc/ 2>/dev/null | grep -qi qemu; then
  echo "=== Install qemu binfmt (cross-arch emulation) ==="
  docker run --privileged --rm tonistiigi/binfmt --install all >/dev/null 2>&1 || true
fi

# buildx 빌더 준비(없으면 생성)
if ! docker buildx inspect "${BUILDER}" >/dev/null 2>&1; then
  echo "=== Create buildx builder: ${BUILDER} ==="
  docker buildx create --name "${BUILDER}" --driver docker-container --use >/dev/null
else
  docker buildx use "${BUILDER}"
fi
docker buildx inspect --bootstrap >/dev/null

echo "=== Build & Push (multi-arch: ${PLATFORMS}) ==="
echo "    ${IMAGE}"
echo "    ${IMAGE_LATEST}"
docker buildx build \
  --platform "${PLATFORMS}" \
  -t "${IMAGE}" \
  -t "${IMAGE_LATEST}" \
  --push \
  "${SCRIPT_DIR}"

echo "=== Done: ${IMAGE} / ${IMAGE_LATEST} (${PLATFORMS}) ==="
