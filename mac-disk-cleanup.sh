#!/bin/bash
# ============================================================
# mac-disk-cleanup.sh — macOS 디스크 정리 스크립트
# ============================================================
# 용도: 주기적 디스크 정리 (cron 또는 launchd)
# 대상: macOS (Apple Silicon / Intel)
# 작성: 2026-06-12
#
# crontab 예시:
#   0 3 * * 0  $HOME/cronjob/mac-disk-cleanup.sh >> $HOME/cronjob/logs/mac-disk-cleanup.log 2>&1
# ============================================================

set -euo pipefail

export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.nvm/versions/node/v24.13.0/bin:/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$PATH"

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

du_bytes() {
  { du -sb "$@" 2>/dev/null || true; } | awk '{sum += $1} END {print sum + 0}'
}

sudo_du_bytes() {
  { sudo du -sb "$@" 2>/dev/null || true; } | awk '{sum += $1} END {print sum + 0}'
}

gb() {
  awk -v bytes="${1:-0}" 'BEGIN { printf "%.2fGB", bytes / 1024 / 1024 / 1024 }'
}

size_to_gb() {
  local value="${1:-0B}"
  value="${value//[[:space:]]/}"
  if [[ "$value" =~ ^([0-9.]+)([KMGT]?B?|B)$ ]]; then
    awk -v n="${BASH_REMATCH[1]}" -v unit="${BASH_REMATCH[2]}" '
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

df_gb() {
  df -P / | awk 'NR == 2 { printf "used=%.2fGB avail=%.2fGB pcent=%s", ($3 - $4) / 1024 / 1024, $4 / 1024 / 1024, $5 }'
}

empty_dir_contents() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
}

# --- 정리 전 현황 ---
BEFORE=$(df_gb)
log "=== 디스크 정리 시작 ($TIMESTAMP) ==="
log "정리 전: $BEFORE"
add_report "📊 **정리 전**: $BEFORE"

# -------------------------------------------------------
# 1. 시스템 로그 정리 (log command & ~/Library/Logs)
# -------------------------------------------------------
log "[1/14] 시스템 로그 정리"
FREED_LOG=0

# macOS system.log 정리
for LOGFILE in /var/log/system.log /var/log/kernel.log; do
  if [ -f "$LOGFILE" ]; then
    SIZE=$(stat -f%z "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 52428800 ]; then  # 50MB
      FREED_LOG=$((FREED_LOG + SIZE))
      sudo truncate -s 0 "$LOGFILE"
      log "  truncated $LOGFILE ($(gb "$SIZE"))"
    fi
  fi
done

# 오래된 로그 파일 정리 (7일 이상)
for LOGDIR in /var/log /private/var/log; do
  [ -d "$LOGDIR" ] && sudo find "$LOGDIR" -name "*.log.*" -mtime +7 -type f -delete 2>/dev/null || true
done

# ASL (Apple System Log) 정리
if command -v log >/dev/null 2>&1; then
  log_size_before=$(log show --predicate 'process == "kernel"' --last 7d 2>/dev/null | wc -l || echo 0)
fi

add_report "1️⃣ 시스템 로그: $(gb "$FREED_LOG") 확보"

# -------------------------------------------------------
# 2. ~/Library 캐시 정리 (macOS specific)
# -------------------------------------------------------
log "[2/14] ~/Library 캐시 정리"
LIBRARY_CACHE_TARGETS=(
  "$HOME/Library/Caches"
  "$HOME/Library/Saved Application State"
  "$HOME/Library/Preferences/com.*.plist"
)
LIBRARY_BEFORE=$(du_bytes "${LIBRARY_CACHE_TARGETS[@]}")

# Xcode derived data 정리
[ -d "$HOME/Library/Developer/Xcode/DerivedData" ] && rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/*

# Application Support 캐시 정리
[ -d "$HOME/Library/Application Support" ] && find "$HOME/Library/Application Support" -xdev -type d -name "Caches" -exec rm -rf {} + 2>/dev/null || true

LIBRARY_AFTER=$(du_bytes "${LIBRARY_CACHE_TARGETS[@]}")
FREED_LIBRARY=$((${LIBRARY_BEFORE:-0} - ${LIBRARY_AFTER:-0}))
[ "$FREED_LIBRARY" -lt 0 ] && FREED_LIBRARY=0
add_report "2️⃣ ~/Library 캐시: $(gb "$FREED_LIBRARY") 확보"

# -------------------------------------------------------
# 3. Homebrew 패키지 정리 (macOS package manager)
# -------------------------------------------------------
log "[3/14] Homebrew 정리"
if command -v brew >/dev/null 2>&1; then
  brew autoremove 2>/dev/null || true
  brew cleanup --prune=all 2>/dev/null || true
  brew cleanup -s 2>/dev/null || true
fi
add_report "3️⃣ Homebrew 정리: 완료"

# -------------------------------------------------------
# 4. Node/npm/npx/nvm 캐시 정리
# -------------------------------------------------------
log "[4/14] Node/npm/npx/nvm 캐시 정리"
NPM_BEFORE=$(du_bytes \
  "$HOME/.npm/_cacache" \
  "$HOME/.npm/_npx" \
  "$HOME/.npm/_logs" \
  "$HOME/.npm/_update-notifier-last-checked" \
  "$HOME/.nvm/.cache" \
  "$HOME/.config/nvm/.cache" \
  "$HOME/.cache/node-gyp" \
  "$HOME/.node-gyp")

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

rm -rf "$HOME/.npm/_cacache" \
       "$HOME/.npm/_npx" \
       "$HOME/.npm/_logs" \
       "$HOME/.npm/_update-notifier-last-checked" \
       "$HOME/.nvm/.cache" \
       "$HOME/.config/nvm/.cache" \
       "$HOME/.cache/node-gyp" \
       "$HOME/.node-gyp" 2>/dev/null || true

NPM_AFTER=$(du_bytes \
  "$HOME/.npm/_cacache" \
  "$HOME/.npm/_npx" \
  "$HOME/.npm/_logs" \
  "$HOME/.npm/_update-notifier-last-checked" \
  "$HOME/.nvm/.cache" \
  "$HOME/.config/nvm/.cache" \
  "$HOME/.cache/node-gyp" \
  "$HOME/.node-gyp")
FREED_NPM=$((${NPM_BEFORE:-0} - ${NPM_AFTER:-0}))
[ "$FREED_NPM" -lt 0 ] && FREED_NPM=0
add_report "4️⃣ Node/npm/npx/nvm 캐시: $(gb "$FREED_NPM") 확보"

# -------------------------------------------------------
# 5. Docker 미사용 이미지 정리 (if installed)
# -------------------------------------------------------
log "[5/14] Docker 미사용 이미지 정리"
if command -v docker >/dev/null 2>&1; then
  DANGLING_OUTPUT=$(docker image prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
  CACHE_OUTPUT=$(docker builder prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
  VOLUME_OUTPUT=$(docker volume prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
  DANGLING_FREED=$(echo "$DANGLING_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
  CACHE_FREED=$(echo "$CACHE_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
  VOLUME_FREED=$(echo "$VOLUME_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
  add_report "5️⃣ Docker 정리: dangling=$(size_to_gb "$DANGLING_FREED") volume=$(size_to_gb "$VOLUME_FREED") cache=$(size_to_gb "$CACHE_FREED") 확보"
else
  add_report "5️⃣ Docker 정리: Docker 미설치"
fi

# -------------------------------------------------------
# 6. /tmp 및 /var/tmp 정리
# -------------------------------------------------------
log "[6/14] /tmp 및 /var/tmp 정리"
TMP_BEFORE=$(du_bytes /tmp /var/tmp)
find /tmp -type f -mtime +7 -not -path "/tmp/.*" -delete 2>/dev/null || true
find /tmp -type d -empty -mtime +7 -not -path "/tmp" -delete 2>/dev/null || true
find /var/tmp -type f -mtime +7 -not -path "/var/tmp/.*" -delete 2>/dev/null || true
find /var/tmp -type d -empty -mtime +7 -delete 2>/dev/null || true
TMP_AFTER=$(du_bytes /tmp /var/tmp)
FREED_TMP=$((${TMP_BEFORE:-0} - ${TMP_AFTER:-0}))
[ "$FREED_TMP" -lt 0 ] && FREED_TMP=0
add_report "6️⃣ /tmp & /var/tmp: $(gb "$FREED_TMP") 확보"

# -------------------------------------------------------
# 7. VSCode 캐시 정리
# -------------------------------------------------------
log "[7/14] VSCode 캐시 정리"
VSCODE_PATHS=(
  "$HOME/.vscode-server/data/CachedExtensionVSIXs"
  "$HOME/.vscode-server/data/logs"
  "$HOME/.vscode/extensions/.cache"
)
VSCODE_BEFORE=$(du_bytes "${VSCODE_PATHS[@]}")
for VSCODE_PATH in "${VSCODE_PATHS[@]}"; do
  empty_dir_contents "$VSCODE_PATH"
done
VSCODE_AFTER=$(du_bytes "${VSCODE_PATHS[@]}")
FREED_VSCODE=$((${VSCODE_BEFORE:-0} - ${VSCODE_AFTER:-0}))
[ "$FREED_VSCODE" -lt 0 ] && FREED_VSCODE=0
add_report "7️⃣ VSCode 캐시: $(gb "$FREED_VSCODE") 확보"

# -------------------------------------------------------
# 8. 휴지통 비우기 (macOS specific)
# -------------------------------------------------------
log "[8/14] 휴지통 비우기"
TRASH_BEFORE=$(du_bytes "$HOME/.Trash")
empty_dir_contents "$HOME/.Trash"
TRASH_AFTER=$(du_bytes "$HOME/.Trash")
FREED_TRASH=$((${TRASH_BEFORE:-0} - ${TRASH_AFTER:-0}))
[ "$FREED_TRASH" -lt 0 ] && FREED_TRASH=0
add_report "8️⃣ 휴지통: $(gb "$FREED_TRASH") 확보"

# -------------------------------------------------------
# 9. 홈 디렉토리 로그 정리
# -------------------------------------------------------
log "[9/14] 홈 디렉토리 로그 정리"
HOME_LOG_TARGETS=(
  "$HOME/.npm/_logs"
  "$HOME/.config/VirtualBox"
  "$HOME/.minecraft/logs"
)
HOME_LOG_BEFORE=$(du_bytes "${HOME_LOG_TARGETS[@]}")
find "$HOME/.npm/_logs" -xdev -type f -name '*.log' -mtime +14 -delete 2>/dev/null || true
find "$HOME/.config/VirtualBox" -xdev -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.*' \) -mtime +30 -delete 2>/dev/null || true
find "$HOME/.minecraft/logs" -xdev -type f \( -name '*.log' -o -name '*.log.gz' \) -mtime +30 -delete 2>/dev/null || true
HOME_LOG_AFTER=$(du_bytes "${HOME_LOG_TARGETS[@]}")
FREED_HOME_LOGS=$((${HOME_LOG_BEFORE:-0} - ${HOME_LOG_AFTER:-0}))
[ "$FREED_HOME_LOGS" -lt 0 ] && FREED_HOME_LOGS=0
add_report "9️⃣ 홈 로그 정리: $(gb "$FREED_HOME_LOGS") 확보"

# -------------------------------------------------------
# 10. Xcode 빌드 및 개발 도구 캐시
# -------------------------------------------------------
log "[10/14] Xcode 및 개발 도구 캐시 정리"
XCODE_PATHS=(
  "$HOME/Library/Developer/Xcode/DerivedData"
  "$HOME/Library/Developer/Xcode/Archives"
  "$HOME/.gradle/caches"
  "$HOME/.m2/repository"
)
XCODE_BEFORE=$(du_bytes "${XCODE_PATHS[@]}")
rm -rf "$HOME/Library/Developer/Xcode/DerivedData"/* 2>/dev/null || true
find "$HOME/.gradle/caches" -type f -mtime +30 -delete 2>/dev/null || true
XCODE_AFTER=$(du_bytes "${XCODE_PATHS[@]}")
FREED_XCODE=$((${XCODE_BEFORE:-0} - ${XCODE_AFTER:-0}))
[ "$FREED_XCODE" -lt 0 ] && FREED_XCODE=0
add_report "🔟 Xcode/개발 캐시: $(gb "$FREED_XCODE") 확보"

# -------------------------------------------------------
# 11. 브라우저 캐시 정리
# -------------------------------------------------------
log "[11/14] 브라우저 캐시 정리"
BROWSER_PATHS=(
  "$HOME/Library/Caches/Google/Chrome"
  "$HOME/Library/Caches/Firefox"
  "$HOME/Library/Safari"
)
BROWSER_BEFORE=$(du_bytes "${BROWSER_PATHS[@]}")
[ -d "$HOME/Library/Caches/Google/Chrome" ] && rm -rf "$HOME/Library/Caches/Google/Chrome/Cache" "$HOME/Library/Caches/Google/Chrome/Cache_Data" 2>/dev/null || true
[ -d "$HOME/Library/Caches/Firefox" ] && find "$HOME/Library/Caches/Firefox" -name "*.sqlite" -delete 2>/dev/null || true
BROWSER_AFTER=$(du_bytes "${BROWSER_PATHS[@]}")
FREED_BROWSER=$((${BROWSER_BEFORE:-0} - ${BROWSER_AFTER:-0}))
[ "$FREED_BROWSER" -lt 0 ] && FREED_BROWSER=0
add_report "1️⃣1️⃣ 브라우저 캐시: $(gb "$FREED_BROWSER") 확보"

# -------------------------------------------------------
# 12. 오래된 임시/편집기 찌꺼기 정리
# -------------------------------------------------------
log "[12/14] 임시 파일 및 편집기 캐시 정리"
CLUTTER_TARGETS=(
  "$HOME/Library/Application Support"
  "$HOME/.cache"
)
CLUTTER_BEFORE=$(du_bytes "${CLUTTER_TARGETS[@]}")
find "$HOME" -maxdepth 1 -type f -mtime +30 \
  \( -name '*~' -o -name '*.tmp' -o -name '*.swp' -o -name '*.swo' -o -name '*.rej' \) \
  -delete 2>/dev/null || true
# .DS_Store 정리 (macOS 시스템 파일)
find "$HOME" -name '.DS_Store' -delete 2>/dev/null || true
CLUTTER_AFTER=$(du_bytes "${CLUTTER_TARGETS[@]}")
FREED_CLUTTER=$((${CLUTTER_BEFORE:-0} - ${CLUTTER_AFTER:-0}))
[ "$FREED_CLUTTER" -lt 0 ] && FREED_CLUTTER=0
add_report "1️⃣2️⃣ 임시/편집기 캐시: $(gb "$FREED_CLUTTER") 확보"

# -------------------------------------------------------
# 13. 언어 파일 및 불필요한 아키텍처 정리
# -------------------------------------------------------
log "[13/14] 언어/아키텍처 파일 정리"
# macOS 시스템에 필요 없는 i386 아키텍처 정리 (Intel Mac의 경우 skip)
ARCH_BEFORE=$(du_bytes "$HOME/.cache" "$HOME/Library/Caches")
find /opt/homebrew/lib -name "*.i386" -delete 2>/dev/null || true
find /usr/local/lib -name "*.i386" -delete 2>/dev/null || true
ARCH_AFTER=$(du_bytes "$HOME/.cache" "$HOME/Library/Caches")
FREED_ARCH=$((${ARCH_BEFORE:-0} - ${ARCH_AFTER:-0}))
[ "$FREED_ARCH" -lt 0 ] && FREED_ARCH=0
add_report "1️⃣3️⃣ 언어/아키텍처 정리: $(gb "$FREED_ARCH") 확보"

# -------------------------------------------------------
# 14. 마지막 스캔: 일반 캐시 정리
# -------------------------------------------------------
log "[14/14] 최종 캐시 정리"
FINAL_TARGETS=(
  "$HOME/.cache"
  "$HOME/Library/Caches"
)
FINAL_BEFORE=$(du_bytes "${FINAL_TARGETS[@]}")
find "$HOME/.cache" -type f -atime +30 -delete 2>/dev/null || true
find "$HOME/Library/Caches" -type f -atime +30 -delete 2>/dev/null || true
FINAL_AFTER=$(du_bytes "${FINAL_TARGETS[@]}")
FREED_FINAL=$((${FINAL_BEFORE:-0} - ${FINAL_AFTER:-0}))
[ "$FREED_FINAL" -lt 0 ] && FREED_FINAL=0
add_report "1️⃣4️⃣ 최종 캐시 정리: $(gb "$FREED_FINAL") 확보"

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
