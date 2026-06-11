#!/bin/bash
# ============================================================
# helm-update.sh — ArgoCD Helm Chart 자동 업데이트
# ============================================================
# 용도: /app/mykubernetes/helm 내 application.yaml의 targetRevision을
#       각 chart repo 최신 버전으로 업데이트 후 git push (ArgoCD 자동 배포)
# 대상: OCI ARM bastion (gateway 서버)
# 작성: 2026-02-11
# ============================================================

set -euo pipefail

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin:$PATH"

HELM_DIR="/app/mykubernetes/helm"
REPORT=""
UPDATED=0
FAILED=0
SKIPPED=0
CHANGES=()

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

add_report() {
  REPORT="${REPORT}\n$*"
}

# --- Git pull (원격 변경사항 먼저 반영) ---
log "Git pull (rebase) 중..."
cd /app/mykubernetes
git fetch origin 2>&1
git pull --rebase origin main 2>&1
log "Git pull 완료"

# --- Helm repo 업데이트 ---
log "Helm repo 업데이트 중..."
helm repo update 2>/dev/null || true

# --- 각 application.yaml 순회 ---
for APP_DIR in "$HELM_DIR"/*/; do
  APP_NAME=$(basename "$APP_DIR")
  APP_FILE="${APP_DIR}application.yaml"

  [ ! -f "$APP_FILE" ] && continue

  # yq v3 호환: -r로 따옴표 제거, sources[0] 우선 → source 폴백
  REPO_URL=$(yq -r '.spec.sources[0].repoURL' "$APP_FILE" 2>/dev/null)
  [ -z "$REPO_URL" ] || [ "$REPO_URL" = "null" ] && REPO_URL=$(yq -r '.spec.source.repoURL' "$APP_FILE" 2>/dev/null)
  CHART=$(yq -r '.spec.sources[0].chart' "$APP_FILE" 2>/dev/null)
  [ -z "$CHART" ] || [ "$CHART" = "null" ] && CHART=$(yq -r '.spec.source.chart' "$APP_FILE" 2>/dev/null)
  CURRENT=$(yq -r '.spec.sources[0].targetRevision' "$APP_FILE" 2>/dev/null)
  [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ] && CURRENT=$(yq -r '.spec.source.targetRevision' "$APP_FILE" 2>/dev/null)

  # chart가 없으면 git-only 관리 (postgresql 등) → skip
  if [ -z "$CHART" ] || [ "$CHART" = "null" ] || [ -z "$CURRENT" ] || [ "$CURRENT" = "null" ] || [ "$CURRENT" = "main" ]; then
    log "[$APP_NAME] git 직접 관리 — skip"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  log "[$APP_NAME] 현재: $CURRENT, chart: $CHART, repo: $REPO_URL"

  # 최신 버전 조회
  LATEST=""

  # OCI registry인 경우 (registry-1.docker.io 등)
  if [[ "$REPO_URL" == registry-* ]] || [[ "$REPO_URL" == oci://* ]]; then
    REPO_REF="$REPO_URL"
    [[ "$REPO_REF" != oci://* ]] && REPO_REF="oci://${REPO_REF}"
    LATEST=$(helm show chart "${REPO_REF}/${CHART}" 2>/dev/null | grep '^version:' | awk '{print $2}') || true
  else
    # 일반 helm repo — URL로 매칭된 repo name 찾기
    REPO_NAME=$(helm repo list -o json 2>/dev/null | jq -r --arg url "$REPO_URL" '.[] | select(.url == $url) | .name' | head -1)
    if [ -z "$REPO_NAME" ]; then
      REPO_NAME="auto-${APP_NAME}"
      helm repo add "$REPO_NAME" "$REPO_URL" --force-update 2>/dev/null || true
      helm repo update "$REPO_NAME" 2>/dev/null || true
    fi
    LATEST=$(helm search repo "${REPO_NAME}/${CHART}" --versions -o json 2>/dev/null | jq -r '.[0].version') || true
  fi

  if [ -z "$LATEST" ] || [ "$LATEST" = "null" ]; then
    log "[$APP_NAME] ⚠️ 최신 버전 조회 실패"
    add_report "❌ **${APP_NAME}**: 최신 버전 조회 실패 (현재: \`${CURRENT}\`)"
    FAILED=$((FAILED + 1))
    continue
  fi

  if [ "$CURRENT" = "$LATEST" ]; then
    log "[$APP_NAME] ✅ 최신 ($CURRENT)"
    add_report "✅ **${APP_NAME}**: \`${CURRENT}\` (최신)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # 업데이트 수행 — yq로 정확히 수정
  log "[$APP_NAME] ⬆️ $CURRENT → $LATEST"

  # sources[0].targetRevision 또는 source.targetRevision 수정
  HAS_SOURCES=$(yq -r '.spec.sources[0].targetRevision' "$APP_FILE" 2>/dev/null)
  if [ -n "$HAS_SOURCES" ] && [ "$HAS_SOURCES" != "null" ]; then
    yq -i ".spec.sources[0].targetRevision = \"${LATEST}\"" "$APP_FILE" 2>/dev/null
  else
    yq -i ".spec.source.targetRevision = \"${LATEST}\"" "$APP_FILE" 2>/dev/null
  fi

  # 변경 확인
  VERIFY=$(yq -r '.spec.sources[0].targetRevision' "$APP_FILE" 2>/dev/null)
  [ -z "$VERIFY" ] || [ "$VERIFY" = "null" ] && VERIFY=$(yq -r '.spec.source.targetRevision' "$APP_FILE" 2>/dev/null)
  if [ "$VERIFY" = "$LATEST" ]; then
    add_report "⬆️ **${APP_NAME}**: \`${CURRENT}\` → \`${LATEST}\`"
    CHANGES+=("${APP_NAME}: ${CURRENT} → ${LATEST}")
    UPDATED=$((UPDATED + 1))
  else
    add_report "❌ **${APP_NAME}**: 파일 수정 실패 (현재: \`${CURRENT}\`, 대상: \`${LATEST}\`)"
    FAILED=$((FAILED + 1))
  fi
done

# --- Git commit & push ---
if [ "$UPDATED" -gt 0 ]; then
  log "Git commit & push..."
  cd /app/mykubernetes

  COMMIT_MSG="chore: weekly helm chart update ($(date '+%Y-%m-%d'))"
  for c in "${CHANGES[@]}"; do
    COMMIT_MSG="${COMMIT_MSG}\n- ${c}"
  done

  git add helm/
  echo -e "$COMMIT_MSG" | git commit -F - 2>&1
  PUSH_RESULT=$(git push origin main 2>&1)

  if [ $? -eq 0 ]; then
    add_report "\n🚀 Git push 완료 — ArgoCD 자동 배포 진행 중"
  else
    add_report "\n❌ Git push 실패: ${PUSH_RESULT}"
    FAILED=$((FAILED + 1))
  fi
else
  log "업데이트 대상 없음"
fi

# --- 보고서 출력 ---
echo ""
echo "========== HELM UPDATE REPORT =========="
echo -e "🔄 **주간 Helm Chart 업데이트** ($(date '+%Y-%m-%d %H:%M'))"
echo -e ""
echo -e "$REPORT"
echo -e ""
echo -e "📊 업데이트: ${UPDATED} | 최신: ${SKIPPED} | 실패: ${FAILED}"
echo "========================================"
