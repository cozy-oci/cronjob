#!/bin/bash
# ============================================================
# mac-disk-cleanup.sh — macOS 디스크 정리 스크립트
# ============================================================
# 용도: 주기적 디스크 정리 (cron 또는 launchd)
# 대상: macOS (Apple Silicon / Intel), Darwin/BSD 유틸 기준
# 작성: 2026-06-12
#
# 설계 원칙:
#   - sudo 미사용: cron/launchd는 사용자 권한으로 실행되므로 시스템 영역(/var/log 등)은
#     건드리지 않고 사용자 홈/캐시만 정리한다. (/var/log는 newsyslog가 자동 회전)
#   - BSD 유틸 기준: du -sk, stat -f, df -Pk, grep -oE 등 macOS 기본 명령만 사용.
#   - 데이터 안전: 캐시/로그/임시파일만, 그것도 mtime/atime 경과 기준으로만 삭제.
#     모델/VM 데이터(.ollama, .minikube, ~/.cache/huggingface, .lmstudio 등)는
#     재다운로드 비용이 매우 크므로 절대 자동 삭제하지 않고 12단계에서 용량만 안내한다.
#
# atime(접근일자) 주의:
#   - APFS는 read 시 atime을 갱신하므로 "-atime +N"은 보수적(최근 읽힌 파일은 보존)이라
#     안전하지만, Spotlight/Time Machine/백신/백업 스캔이 atime을 자주 건드려
#     공간 회수량은 적을 수 있다. 따라서 캐시 정리는 mtime을 1차 기준으로,
#     atime은 "오래 안 쓴 파일" 식별 보조 기준으로만 사용한다.
#
# crontab 예시:
#   0 3 * * 0  $HOME/cronjob/mac-disk-cleanup.sh >> $HOME/cronjob/logs/mac-disk-cleanup.log 2>&1
#
# launchd 예시: ~/Library/LaunchAgents/com.user.disk-cleanup.plist (StartCalendarInterval)
# ============================================================

set -euo pipefail

# Apple Silicon(/opt/homebrew) 및 Intel(/usr/local) Homebrew 경로 모두 포함
export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.nvm/versions/node/v24.13.0/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

LOG_DIR="$HOME/cronjob/logs"
mkdir -p "$LOG_DIR"

TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S %Z')
REPORT=""

load_discord_env() {
  if [[ -z "${DISCORD_TOKEN:-}" || -z "${CHANNEL_UPDATE:-}" ]]; then
    # cron does not load interactive shell config by default.
    # Import only Discord exports because .zshrc may contain zsh-only syntax.
    # shellcheck source=/dev/null
    [[ -r $HOME/.park_reserve.env ]] && source <(grep -E '^export DISCORD_TOKEN=' $HOME/.park_reserve.env) || true
    # shellcheck source=/dev/null
    [[ -r $HOME/.zshrc ]] && source <(grep -E '^export (DISCORD_TOKEN|CHANNEL_UPDATE)=' $HOME/.zshrc) || true
  fi
}

send_discord_report() {
  local channel="${1:-}"
  local message="$2"

  load_discord_env
  channel="${channel:-${CHANNEL_UPDATE:-}}"

  if [[ -z "${DISCORD_TOKEN:-}" || -z "$channel" ]]; then
    log "[Discord] DISCORD_TOKEN 또는 채널 ID가 없어 전송을 건너뜀"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "[Discord] jq가 없어 전송을 건너뜀"
    return 0
  fi

  if (( ${#message} > 1900 )); then
    message="${message:0:1850}"$'\n... (truncated)'
  fi

  if ! curl -fsS -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
    -H "Authorization: Bot ${DISCORD_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg msg "$message" '{content:$msg}')" >/dev/null; then
    log "[Discord] 리포트 전송 실패"
  fi
}

log() {
  echo "[$(date '+%H:%M:%S')] $*"
}

add_report() {
  REPORT="${REPORT}\n$*"
}

# BSD du에는 -b(바이트)가 없으므로 -sk(1024블록 KB)로 측정 후 바이트로 환산.
du_bytes() {
  { du -sk "$@" 2>/dev/null || true; } | awk '{sum += $1} END {print (sum + 0) * 1024}'
}

gb() {
  awk -v bytes="${1:-0}" 'BEGIN { printf "%.2fGB", bytes / 1024 / 1024 / 1024 }'
}

size_to_gb() {
  local value="${1:-0B}"
  value="${value//[[:space:]]/}"
  if [[ "$value" =~ ^([0-9.]+)([KkMGT]?i?B?|B)$ ]]; then
    local unit="${BASH_REMATCH[2]}"
    unit="${unit//i/}"
    unit=$(printf '%s' "$unit" | tr '[:lower:]' '[:upper:]')
    awk -v n="${BASH_REMATCH[1]}" -v unit="$unit" '
      BEGIN {
        if (unit == "K" || unit == "KB") n *= 1024
        else if (unit == "M" || unit == "MB") n *= 1024 * 1024
        else if (unit == "G" || unit == "GB") n *= 1024 * 1024 * 1024
        else if (unit == "T" || unit == "TB") n *= 1024 * 1024 * 1024 * 1024
        printf "%.2fGB", n / 1024 / 1024 / 1024
      }'
  else
    printf "%s" "$value"
  fi
}

# BSD df: -P(POSIX) -k(1024블록). 컬럼 = Filesystem 1024-blocks Used Avail Capacity Mounted
df_gb() {
  df -Pk / | awk 'NR == 2 { printf "used=%.2fGB avail=%.2fGB pcent=%s", $3 / 1024 / 1024, $4 / 1024 / 1024, $5 }'
}

empty_dir_contents() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  while IFS= read -r -d '' entry; do
    rm -rf "$entry" 2>/dev/null || true
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
}

# 디렉토리 내 mtime N일 경과 일반 파일 + 빈 디렉토리만 삭제 (동일 볼륨 한정).
# 캐시/로그 정리의 표준 패턴: 재생성 가능한 파일만, 오래된 것만.
prune_old() {
  local dir="$1" days="${2:-7}"
  [[ -d "$dir" ]] || return 0
  find "$dir" -xdev -type f -mtime +"$days" -delete 2>/dev/null || true
  find "$dir" -xdev -mindepth 1 -type d -empty -mtime +"$days" -delete 2>/dev/null || true
}

# --- 정리 전 현황 ---
BEFORE=$(df_gb)
log "=== 디스크 정리 시작 ($TIMESTAMP) ==="
log "정리 전: $BEFORE"
add_report "📊 **정리 전**: $BEFORE"

# -------------------------------------------------------
# 1. ~/Library 캐시 정리 (브라우저/앱 캐시 포함, macOS 핵심)
# -------------------------------------------------------
# ~/Library/Caches 아래에 Chrome/Firefox/Safari/각종 앱 캐시가 모두 모여 있다.
# 실행 중인 앱이 재다운로드할 수 있도록 7일 경과 파일만 삭제(전체 삭제 지양).
log "[1/12] ~/Library 캐시 정리"
LIBRARY_TARGETS=(
  "$HOME/Library/Caches"
  "$HOME/Library/Saved Application State"
)
LIBRARY_BEFORE=$(du_bytes "${LIBRARY_TARGETS[@]}")
if [[ -d "$HOME/Library/Caches" ]]; then
  find "$HOME/Library/Caches" -xdev -type f -mtime +7 -delete 2>/dev/null || true
  find "$HOME/Library/Caches" -xdev -type d -empty -mtime +7 -delete 2>/dev/null || true
fi
if [[ -d "$HOME/Library/Saved Application State" ]]; then
  find "$HOME/Library/Saved Application State" -xdev -type f -mtime +14 -delete 2>/dev/null || true
fi
LIBRARY_AFTER=$(du_bytes "${LIBRARY_TARGETS[@]}")
FREED_LIBRARY=$((${LIBRARY_BEFORE:-0} - ${LIBRARY_AFTER:-0}))
[ "$FREED_LIBRARY" -lt 0 ] && FREED_LIBRARY=0
add_report "1️⃣ ~/Library 캐시: $(gb "$FREED_LIBRARY") 확보"

# -------------------------------------------------------
# 2. 샌드박스 앱 컨테이너 캐시 정리 (Containers / Group Containers)
# -------------------------------------------------------
# 샌드박스 앱(Mail, Safari, Teams, 시스템 데몬 등)의 캐시는 ~/Library/Caches가 아니라
# ~/Library/Containers/<bundle>/Data/Library/Caches 와 Group Containers 아래에 따로 쌓인다.
# 캐시 디렉토리(.../Library/Caches)만, 7일 경과 파일만 삭제 → 앱 데이터(Documents 등)는 보존.
log "[2/12] 컨테이너 캐시 정리"
CONTAINER_CACHES=()
while IFS= read -r -d '' c; do CONTAINER_CACHES+=("$c"); done < <(
  find "$HOME/Library/Containers" -maxdepth 4 -type d -name Caches -path '*/Data/Library/Caches' -print0 2>/dev/null
  find "$HOME/Library/Group Containers" -maxdepth 3 -type d -name Caches -path '*/Library/Caches' -print0 2>/dev/null
)
CONTAINER_FREED=0
if (( ${#CONTAINER_CACHES[@]} > 0 )); then
  CONTAINER_BEFORE=$(du_bytes "${CONTAINER_CACHES[@]}")
  for c in "${CONTAINER_CACHES[@]}"; do prune_old "$c" 7; done
  CONTAINER_AFTER=$(du_bytes "${CONTAINER_CACHES[@]}")
  CONTAINER_FREED=$((${CONTAINER_BEFORE:-0} - ${CONTAINER_AFTER:-0}))
  [ "$CONTAINER_FREED" -lt 0 ] && CONTAINER_FREED=0
fi
add_report "2️⃣ 컨테이너 캐시: $(gb "$CONTAINER_FREED") 확보 (${#CONTAINER_CACHES[@]}개 앱)"

# -------------------------------------------------------
# 3. Homebrew 정리 (macOS 패키지 매니저)
# -------------------------------------------------------
log "[3/12] Homebrew 정리"
BREW_FREED=0
if command -v brew >/dev/null 2>&1; then
  BREW_CACHE_DIR=$(brew --cache 2>/dev/null || true)
  BREW_BEFORE=$(du_bytes "$BREW_CACHE_DIR")
  HOMEBREW_NO_AUTO_UPDATE=1 brew autoremove 2>/dev/null || true
  HOMEBREW_NO_AUTO_UPDATE=1 brew cleanup -s --prune=all 2>/dev/null || true
  BREW_AFTER=$(du_bytes "$BREW_CACHE_DIR")
  BREW_FREED=$((${BREW_BEFORE:-0} - ${BREW_AFTER:-0}))
  [ "$BREW_FREED" -lt 0 ] && BREW_FREED=0
  add_report "3️⃣ Homebrew: $(gb "$BREW_FREED") 확보"
else
  add_report "3️⃣ Homebrew: 미설치"
fi

# -------------------------------------------------------
# 4. Node/npm/npx/nvm + yarn/pnpm 캐시 정리
# -------------------------------------------------------
log "[4/12] Node/npm/npx/nvm 캐시 정리"
NPM_TARGETS=(
  "$HOME/.npm/_cacache"
  "$HOME/.npm/_npx"
  "$HOME/.npm/_logs"
  "$HOME/.npm/_update-notifier-last-checked"
  "$HOME/.nvm/.cache"
  "$HOME/.config/nvm/.cache"
  "$HOME/.cache/node-gyp"
  "$HOME/.node-gyp"
)
NPM_BEFORE=$(du_bytes "${NPM_TARGETS[@]}")

NPM_BIN=""
if command -v npm >/dev/null 2>&1; then
  NPM_BIN=$(command -v npm)
elif [[ -x "$HOME/.nvm/versions/node/v24.13.0/bin/npm" ]]; then
  NPM_BIN="$HOME/.nvm/versions/node/v24.13.0/bin/npm"
fi

if [[ -n "$NPM_BIN" ]]; then
  "$NPM_BIN" cache clean --force --silent 2>/dev/null || true
  "$NPM_BIN" cache verify --silent 2>/dev/null || true
fi

rm -rf "${NPM_TARGETS[@]}" 2>/dev/null || true

# yarn/pnpm는 자체 prune 명령으로 안전하게 정리 (전역 store만, 프로젝트 영향 없음)
command -v yarn >/dev/null 2>&1 && yarn cache clean >/dev/null 2>&1 || true
command -v pnpm >/dev/null 2>&1 && pnpm store prune >/dev/null 2>&1 || true

NPM_AFTER=$(du_bytes "${NPM_TARGETS[@]}")
FREED_NPM=$((${NPM_BEFORE:-0} - ${NPM_AFTER:-0}))
[ "$FREED_NPM" -lt 0 ] && FREED_NPM=0
add_report "4️⃣ Node/npm/npx/nvm 캐시: $(gb "$FREED_NPM") 확보"

# -------------------------------------------------------
# 5. Docker 미사용 이미지/빌드캐시 정리 (Docker Desktop, 설치 시에만)
# -------------------------------------------------------
# dangling 이미지와 빌드 캐시만 제거. volume prune은 정지/삭제된 컨테이너의
# named/anonymous 볼륨(DB 데이터 등)을 영구 삭제할 수 있어 개발 머신에서는 제외.
log "[5/12] Docker 미사용 이미지/빌드캐시 정리"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  DANGLING_OUTPUT=$(docker image prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
  CACHE_OUTPUT=$(docker builder prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
  DANGLING_FREED=$(echo "$DANGLING_OUTPUT" | grep -oE '[0-9.]+ *[KMGT]?B' | head -1 || echo "0B")
  CACHE_FREED=$(echo "$CACHE_OUTPUT" | grep -oE '[0-9.]+ *[KMGT]?B' | head -1 || echo "0B")
  add_report "5️⃣ Docker 정리: dangling=$(size_to_gb "$DANGLING_FREED") cache=$(size_to_gb "$CACHE_FREED") 확보"
else
  add_report "5️⃣ Docker 정리: 미설치 또는 미실행"
fi

# -------------------------------------------------------
# 6. 임시 디렉토리 정리 (/private/tmp, /private/var/tmp)
# -------------------------------------------------------
# macOS의 /tmp, /var/tmp는 /private/... 심볼릭 링크이므로 실제 경로를 직접 지정.
# sudo 미사용이라 본인 소유 파일만 정리된다(타 사용자/시스템 파일은 권한 거부로 건너뜀).
# 숨김파일(.*)은 실행 중 앱의 락/소켓일 수 있어 의도적으로 건드리지 않는다.
log "[6/12] 임시 디렉토리 정리"
TMP_TARGETS=(/private/tmp /private/var/tmp)
TMP_BEFORE=$(du_bytes "${TMP_TARGETS[@]}")
for TMPDIR_PATH in "${TMP_TARGETS[@]}"; do
  [ -d "$TMPDIR_PATH" ] || continue
  find "$TMPDIR_PATH" -xdev -type f -mtime +7 -not -name '.*' -delete 2>/dev/null || true
  find "$TMPDIR_PATH" -xdev -mindepth 1 -type d -empty -mtime +7 -delete 2>/dev/null || true
done
TMP_AFTER=$(du_bytes "${TMP_TARGETS[@]}")
FREED_TMP=$((${TMP_BEFORE:-0} - ${TMP_AFTER:-0}))
[ "$FREED_TMP" -lt 0 ] && FREED_TMP=0
add_report "6️⃣ 임시 디렉토리: $(gb "$FREED_TMP") 확보"

# -------------------------------------------------------
# 7. 휴지통 비우기 (macOS)
# -------------------------------------------------------
log "[7/12] 휴지통 비우기"
TRASH_BEFORE=$(du_bytes "$HOME/.Trash")
empty_dir_contents "$HOME/.Trash"
TRASH_AFTER=$(du_bytes "$HOME/.Trash")
FREED_TRASH=$((${TRASH_BEFORE:-0} - ${TRASH_AFTER:-0}))
[ "$FREED_TRASH" -lt 0 ] && FREED_TRASH=0
add_report "7️⃣ 휴지통: $(gb "$FREED_TRASH") 확보"

# -------------------------------------------------------
# 8. VSCode 캐시 정리
# -------------------------------------------------------
log "[8/12] VSCode 캐시 정리"
VSCODE_PATHS=(
  "$HOME/.vscode-server/data/CachedExtensionVSIXs"
  "$HOME/.vscode-server/data/logs"
  "$HOME/Library/Application Support/Code/Cache"
  "$HOME/Library/Application Support/Code/CachedData"
  "$HOME/Library/Application Support/Code/CachedExtensionVSIXs"
  "$HOME/Library/Application Support/Code/GPUCache"
  "$HOME/Library/Application Support/Code/logs"
)
VSCODE_BEFORE=$(du_bytes "${VSCODE_PATHS[@]}")
for VSCODE_PATH in "${VSCODE_PATHS[@]}"; do
  empty_dir_contents "$VSCODE_PATH"
done
VSCODE_AFTER=$(du_bytes "${VSCODE_PATHS[@]}")
FREED_VSCODE=$((${VSCODE_BEFORE:-0} - ${VSCODE_AFTER:-0}))
[ "$FREED_VSCODE" -lt 0 ] && FREED_VSCODE=0
add_report "8️⃣ VSCode 캐시: $(gb "$FREED_VSCODE") 확보"

# -------------------------------------------------------
# 9. Xcode / 개발 도구 캐시 정리
# -------------------------------------------------------
# DerivedData는 재생성되는 빌드 산출물이라 전체 삭제 안전.
# Archives는 배포용 아카이브라 자동 삭제하지 않는다.
# gradle/m2는 캐시이나 재다운로드 비용이 크므로 30일 경과분만 정리.
# iOS/watchOS DeviceSupport는 기기 재연결 시 재생성되므로 30일 경과 버전만 제거.
# simctl delete unavailable: 더 이상 사용 불가한 시뮬레이터 기기 제거(수 GB 회수 가능).
log "[9/12] Xcode/개발 도구 캐시 정리"
DEV_TARGETS=(
  "$HOME/Library/Developer/Xcode/DerivedData"
  "$HOME/Library/Developer/CoreSimulator/Caches"
  "$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  "$HOME/Library/Developer/Xcode/watchOS DeviceSupport"
  "$HOME/Library/Developer/Xcode/tvOS DeviceSupport"
  "$HOME/.gradle/caches"
  "$HOME/.m2/repository"
)
DEV_BEFORE=$(du_bytes "${DEV_TARGETS[@]}")
empty_dir_contents "$HOME/Library/Developer/Xcode/DerivedData"
empty_dir_contents "$HOME/Library/Developer/CoreSimulator/Caches"
for ds in "iOS" "watchOS" "tvOS"; do
  find "$HOME/Library/Developer/Xcode/${ds} DeviceSupport" -xdev -mindepth 1 -maxdepth 1 -type d -mtime +30 \
    -exec rm -rf {} + 2>/dev/null || true
done
# 빌드 시 재다운로드되는 의존성 캐시는 30일 경과분만 (오프라인 재현성 영향 최소화)
find "$HOME/.gradle/caches" -xdev -type f -mtime +30 -delete 2>/dev/null || true
find "$HOME/.m2/repository" -xdev -type f -mtime +30 -delete 2>/dev/null || true
# 사용 불가 시뮬레이터 제거 (전체 Xcode 설치 시에만 simctl 존재)
if xcrun simctl help >/dev/null 2>&1; then
  xcrun simctl delete unavailable >/dev/null 2>&1 || true
fi
DEV_AFTER=$(du_bytes "${DEV_TARGETS[@]}")
FREED_DEV=$((${DEV_BEFORE:-0} - ${DEV_AFTER:-0}))
[ "$FREED_DEV" -lt 0 ] && FREED_DEV=0
add_report "9️⃣ Xcode/개발 캐시: $(gb "$FREED_DEV") 확보"

# -------------------------------------------------------
# 10. ~/.cache 및 ~/Library/Logs 정리
# -------------------------------------------------------
# ~/.cache 는 atime 30일 경과 파일만 삭제(보수적). 단, huggingface 캐시는 심볼릭
# 링크 blob 저장소라 개별 파일을 지우면 캐시가 깨지고 재다운로드(수십 GB) 비용이
# 막대하므로 prune으로 제외하고, 그 안의 로그만 따로 정리한다. uv는 자체 prune 사용.
log "[10/12] ~/.cache · ~/Library/Logs 정리"
CACHE_TARGETS=(
  "$HOME/.cache"
  "$HOME/Library/Logs"
)
CACHE_BEFORE=$(du_bytes "${CACHE_TARGETS[@]}")
# huggingface/ollama 등 모델 blob 저장소는 제외하고 일반 캐시 파일만 atime 30일 경과 삭제
find "$HOME/.cache" -xdev \( -path '*/huggingface/*' -o -path '*/huggingface' \) -prune \
  -o -type f -atime +30 -delete 2>/dev/null || true
# HF 캐시 내부의 로그/임시 파일만 안전하게 정리 (blob/snapshot은 보존)
find "$HOME/.cache/huggingface" -xdev -type f -path '*/logs/*' -mtime +14 -delete 2>/dev/null || true
command -v uv >/dev/null 2>&1 && uv cache prune >/dev/null 2>&1 || true
# 사용자 앱 로그 / 진단 리포트 (시스템 로그 /var/log 는 newsyslog가 회전)
find "$HOME/Library/Logs" -xdev -type f -mtime +30 -delete 2>/dev/null || true
find "$HOME/Library/Logs" -xdev -mindepth 1 -type d -empty -mtime +30 -delete 2>/dev/null || true
CACHE_AFTER=$(du_bytes "${CACHE_TARGETS[@]}")
FREED_CACHE=$((${CACHE_BEFORE:-0} - ${CACHE_AFTER:-0}))
[ "$FREED_CACHE" -lt 0 ] && FREED_CACHE=0
add_report "🔟 ~/.cache·Logs: $(gb "$FREED_CACHE") 확보"

# -------------------------------------------------------
# 11. 홈 디렉토리 로그/찌꺼기 및 .DS_Store 정리
# -------------------------------------------------------
log "[11/12] 홈 로그/찌꺼기 정리"
HOME_TARGETS=(
  "$HOME/.npm/_logs"
  "$HOME/.config/VirtualBox"
  "$HOME/.minecraft/logs"
  "$HOME/.bash_sessions"
)
HOME_BEFORE=$(du_bytes "${HOME_TARGETS[@]}")
# 각종 앱 로그
find "$HOME/.npm/_logs" -xdev -type f -name '*.log' -mtime +14 -delete 2>/dev/null || true
find "$HOME/.config/VirtualBox" -xdev -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.*' \) -mtime +30 -delete 2>/dev/null || true
find "$HOME/.minecraft/logs" -xdev -type f \( -name '*.log' -o -name '*.log.gz' \) -mtime +30 -delete 2>/dev/null || true
# Terminal 세션 복원 찌꺼기 (macOS 고유, 무한 누적)
find "$HOME/.bash_sessions" -xdev -type f -mtime +30 -delete 2>/dev/null || true
# 홈 최상위 편집기 찌꺼기 (30일 경과)
find "$HOME" -xdev -maxdepth 1 -type f -mtime +30 \
  \( -name '*~' -o -name '*.tmp' -o -name '*.swp' -o -name '*.swo' -o -name '*.rej' \) \
  -delete 2>/dev/null || true
# .DS_Store 정리 (홈 트리, 동일 볼륨 한정).
# 대용량 모델/VM 디렉토리·VCS·node_modules·Library는 순회에서 prune → 속도/안전 확보.
find "$HOME" -xdev \
  \( -name '.git' -o -name 'node_modules' -o -name '.ollama' -o -name '.minikube' \
     -o -name '.lmstudio' -o -name 'Library' \) -prune \
  -o -name '.DS_Store' -type f -delete 2>/dev/null || true
HOME_AFTER=$(du_bytes "${HOME_TARGETS[@]}")
FREED_HOME=$((${HOME_BEFORE:-0} - ${HOME_AFTER:-0}))
[ "$FREED_HOME" -lt 0 ] && FREED_HOME=0
add_report "1️⃣1️⃣ 홈 로그/찌꺼기: $(gb "$FREED_HOME") 확보"

# -------------------------------------------------------
# 12. Time Machine 로컬 스냅샷 + 대용량 비-캐시 디렉토리 안내
# -------------------------------------------------------
# 로컬 APFS 스냅샷은 수십 GB를 점유할 수 있다. 스냅샷 삭제/thinning은 권한이 필요하므로
# best-effort(실패 시 무시)로 시도하고, 실패해도 현황만 보고한다.
log "[12/12] Time Machine 스냅샷 · 대용량 디렉토리 안내"
if command -v tmutil >/dev/null 2>&1; then
  SNAP_COUNT=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
  if [[ "${SNAP_COUNT:-0}" -gt 0 ]]; then
    # 최소 20GB 여유를 목표로 긴급도 4로 thinning 시도 (권한 없으면 무시됨)
    tmutil thinlocalsnapshots / 21474836480 4 >/dev/null 2>&1 || true
    SNAP_AFTER=$(tmutil listlocalsnapshots / 2>/dev/null | grep -c 'com.apple.TimeMachine' || true)
    add_report "1️⃣2️⃣ 로컬 스냅샷: ${SNAP_COUNT}개 → ${SNAP_AFTER:-$SNAP_COUNT}개"
  else
    add_report "1️⃣2️⃣ 로컬 스냅샷: 없음"
  fi
fi
# 자동 삭제하지 않는 대용량 모델/VM 데이터 안내 (재다운로드 비용이 커 수동 검토 권장)
ADVISORY_DIRS=(
  "$HOME/.ollama"
  "$HOME/.minikube"
  "$HOME/.cache/huggingface"
  "$HOME/.lmstudio"
  "$HOME/Library/Application Support/MobileSync/Backup"
)
ADVISORY=""
for d in "${ADVISORY_DIRS[@]}"; do
  [[ -d "$d" ]] || continue
  sz=$(du_bytes "$d")
  # 5GB 이상만 안내
  if (( sz >= 5 * 1024 * 1024 * 1024 )); then
    ADVISORY="${ADVISORY}\n   • ${d/#$HOME/~} — $(gb "$sz")"
  fi
done
if [[ -n "$ADVISORY" ]]; then
  add_report "📦 **대용량(수동 검토 권장, 자동 삭제 안 함)**:${ADVISORY}"
fi

# --- 정리 후 현황 ---
AFTER=$(df_gb)
log "정리 후: $AFTER"
log "=== 디스크 정리 완료 ==="

add_report ""
add_report "📊 **정리 후**: $AFTER"

# --- 보고서 출력 ---
echo ""
echo "========== CLEANUP REPORT =========="
echo -e "$REPORT"
echo "===================================="

DISCORD_MESSAGE=$(printf '디스크 정리 리포트 — %s\n%b' "$TIMESTAMP" "$REPORT")
send_discord_report "${CHANNEL_UPDATE:-}" "$DISCORD_MESSAGE"
