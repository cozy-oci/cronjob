#!/bin/bash
# ============================================================
# disk-cleanup.sh — Gateway 서버 디스크 정리 스크립트
# ============================================================
# 용도: 주기적 디스크 정리 (OpenClaw cron 또는 OS crontab)
# 대상: OCI ARM bastion (Ubuntu)
# 작성: 2026-02-11
#
# OS crontab 예시:
#   0 3 * * 0  $HOME/cronjob/disk-cleanup.sh >> $HOME/cronjob/logs/disk-cleanup.log 2>&1
# ============================================================

set -euo pipefail

export PATH="$HOME/bin:$HOME/.local/bin:$HOME/.nvm/versions/node/v24.13.0/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin:$PATH"

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
  df -B1 / --output=used,avail,pcent | awk 'NR == 2 { printf "used=%.2fGB avail=%.2fGB pcent=%s", $1 / 1024 / 1024 / 1024, $2 / 1024 / 1024 / 1024, $3 }'
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
# 1. 시스템 로그 정리
# -------------------------------------------------------
log "[1/17] 시스템 로그 정리"
FREED_LOG=0

# 오래된 로그 파일 삭제 (7일 이상) — *.log-* 및 *.log.[0-9]* 패턴 모두 처리
for PATTERN in "*.log-*" "*.log.[0-9]*"; do
  COUNT=$(sudo find /var/log -name "$PATTERN" -mtime +7 -type f 2>/dev/null | wc -l)
  if [ "$COUNT" -gt 0 ]; then
    SIZE=$(sudo find /var/log -name "$PATTERN" -mtime +7 -type f -exec du -cb {} + 2>/dev/null | tail -1 | cut -f1)
    sudo find /var/log -name "$PATTERN" -mtime +7 -type f -delete 2>/dev/null || true
    FREED_LOG=$((FREED_LOG + ${SIZE:-0}))
  fi
done

# oracle-cloud-agent 압축 로그 삭제
OCA_GZ_SIZE=$(sudo find /var/log/oracle-cloud-agent -name "*.gz" -type f -exec du -cb {} + 2>/dev/null | tail -1 | cut -f1 || echo 0)
sudo find /var/log/oracle-cloud-agent -name "*.gz" -type f -delete 2>/dev/null || true
FREED_LOG=$((FREED_LOG + ${OCA_GZ_SIZE:-0}))

# btmp (실패 로그인 기록) — 이전 달 삭제, 현재 truncate
sudo find /var/log -name "btmp-*" -delete 2>/dev/null || true
if [ -f /var/log/btmp ] && [ "$(stat -c%s /var/log/btmp 2>/dev/null || echo 0)" -gt 1048576 ]; then
  FREED_LOG=$((FREED_LOG + $(stat -c%s /var/log/btmp)))
  sudo truncate -s 0 /var/log/btmp
fi

# syslog, auth.log, kern.log, dpkg.log, apt 로그, xrdp 로그 — 50MB 초과 시 truncate
for LOGFILE in /var/log/syslog /var/log/auth.log /var/log/kern.log /var/log/dpkg.log /var/log/apt/history.log /var/log/apt/term.log /var/log/unattended-upgrades/unattended-upgrades.log /var/log/xrdp.log; do
  if [ -f "$LOGFILE" ]; then
    SIZE=$(sudo stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 52428800 ]; then  # 50MB
      FREED_LOG=$((FREED_LOG + SIZE))
      sudo truncate -s 0 "$LOGFILE"
      log "  truncated $LOGFILE ($(gb "$SIZE"))"
    fi
  fi
done

add_report "1️⃣ 시스템 로그: $(gb "$FREED_LOG") 확보"

# -------------------------------------------------------
# 2. journald 로그 정리 (7일 보관)
# -------------------------------------------------------
log "[2/17] journald 정리"
JOURNAL_BEFORE=$(sudo journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
sudo journalctl --vacuum-time=7d --quiet 2>/dev/null || true
sudo journalctl --vacuum-size=512M --quiet 2>/dev/null || true
JOURNAL_AFTER=$(sudo journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
add_report "2️⃣ journald: $(size_to_gb "$JOURNAL_BEFORE") → $(size_to_gb "$JOURNAL_AFTER")"

# -------------------------------------------------------
# 3. apt autoremove (불필요 패키지 제거) — clean 전에 먼저 실행
# -------------------------------------------------------
log "[3/17] apt autoremove"
AUTOREMOVE_OUTPUT=$(sudo apt-get autoremove -y 2>&1 || true)
if echo "$AUTOREMOVE_OUTPUT" | grep -Eq '^[[:space:]]*0 upgraded, 0 newly installed, 0 to remove'; then
  AUTOREMOVE_OUTPUT="Nothing to do"
elif [[ "$AUTOREMOVE_OUTPUT" =~ After[[:space:]]this[[:space:]]operation,[[:space:]]([0-9.]+)[[:space:]]([KMGT]?i?B?|[KMGT])[[:space:]]of[[:space:]]disk[[:space:]]space[[:space:]]will[[:space:]]be[[:space:]]freed ]]; then
  AUTOREMOVE_UNIT="${BASH_REMATCH[2]//i/}"
  AUTOREMOVE_OUTPUT="Freed space: $(size_to_gb "${BASH_REMATCH[1]}${AUTOREMOVE_UNIT}")"
elif echo "$AUTOREMOVE_OUTPUT" | grep -q '^E:'; then
  AUTOREMOVE_OUTPUT="Failed: $(echo "$AUTOREMOVE_OUTPUT" | grep '^E:' | head -1)"
else
  AUTOREMOVE_OUTPUT="Completed"
fi
add_report "3️⃣ apt autoremove: ${AUTOREMOVE_OUTPUT}"

# -------------------------------------------------------
# 4. Node/npm/npx/nvm 캐시 정리
# -------------------------------------------------------
log "[4/17] Node/npm/npx/nvm 캐시 정리"
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
# 5. Homebrew 및 유저 캐시 정리
# -------------------------------------------------------
log "[5/17] Homebrew 및 유저 캐시 정리"
HOMEBREW_CACHE_DIR=""
if command -v brew >/dev/null 2>&1; then
  HOMEBREW_CACHE_DIR=$(brew --cache 2>/dev/null || true)
fi

USER_CACHE_TARGETS=("$HOME/.cache" /home/linuxbrew/.linuxbrew/var/homebrew)
if [[ -n "$HOMEBREW_CACHE_DIR" && "$HOMEBREW_CACHE_DIR" != "$HOME/.cache" && "$HOMEBREW_CACHE_DIR" != "$HOME/.cache/"* ]]; then
  USER_CACHE_TARGETS+=("$HOMEBREW_CACHE_DIR")
fi

USER_BEFORE=$(du_bytes "${USER_CACHE_TARGETS[@]}")
if command -v brew >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew autoremove 2>/dev/null || true
  HOMEBREW_NO_AUTO_UPDATE=1 brew cleanup -s --prune=all 2>/dev/null || true
fi

for CACHE_DIR in Homebrew mozilla microsoft-edge pip node-gyp bbrew helm gnome-software; do
  empty_dir_contents "$HOME/.cache/$CACHE_DIR"
done
empty_dir_contents "$HOMEBREW_CACHE_DIR"
empty_dir_contents "/home/linuxbrew/.linuxbrew/var/homebrew/logs"
empty_dir_contents "/home/linuxbrew/.linuxbrew/var/homebrew/locks"
empty_dir_contents "/home/linuxbrew/.linuxbrew/var/homebrew/tmp"

USER_AFTER=$(du_bytes "${USER_CACHE_TARGETS[@]}")
FREED_USER=$((${USER_BEFORE:-0} - ${USER_AFTER:-0}))
[ "$FREED_USER" -lt 0 ] && FREED_USER=0
add_report "5️⃣ Homebrew 및 유저 캐시: $(gb "$FREED_USER") 확보"

# -------------------------------------------------------
# 6. Docker 미사용 이미지 정리
# -------------------------------------------------------
log "[6/17] Docker 미사용 이미지 정리"
DOCKER_BEFORE_BYTES=$(docker system df --format '{{json .}}' 2>/dev/null | awk -F'"' '/"TotalCount"/{for(i=1;i<=NF;i++) if($i=="Size") print $(i+2)}' || echo 0)
# prune -a 는 정지된 컨테이너(minikube 등)까지 삭제하므로 사용 금지.
# dangling 이미지(태그 없는 레이어)와 빌드 캐시만 제거한다.
DANGLING_OUTPUT=$(docker image prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
CACHE_OUTPUT=$(docker builder prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
# 컨테이너(실행 중 + 정지 중 모두)에 연결되지 않은 볼륨만 삭제
VOLUME_OUTPUT=$(docker volume prune -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
DANGLING_FREED=$(echo "$DANGLING_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
CACHE_FREED=$(echo "$CACHE_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
VOLUME_FREED=$(echo "$VOLUME_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
add_report "6️⃣ Docker 정리: dangling=$(size_to_gb "$DANGLING_FREED") volume=$(size_to_gb "$VOLUME_FREED") cache=$(size_to_gb "$CACHE_FREED") 확보"

# -------------------------------------------------------
# 7. 패키지 캐시 정리 (apt + PackageKit) — autoremove 후 마지막에 정리
# -------------------------------------------------------
log "[7/17] 패키지 캐시 정리"
CACHE_BEFORE=$({ sudo du -sb /var/cache/apt /var/lib/apt/lists /var/cache/PackageKit 2>/dev/null || true; } | awk '{s+=$1}END{print s+0}')
sudo apt-get clean 2>/dev/null || true
sudo apt-get autoclean -y 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/* 2>/dev/null || true
sudo mkdir -p /var/lib/apt/lists/partial 2>/dev/null || true
sudo rm -rf /var/cache/PackageKit/* 2>/dev/null || true
CACHE_AFTER=$({ sudo du -sb /var/cache/apt /var/lib/apt/lists /var/cache/PackageKit 2>/dev/null || true; } | awk '{s+=$1}END{print s+0}')
FREED_CACHE=$((CACHE_BEFORE - CACHE_AFTER))
[ "$FREED_CACHE" -lt 0 ] && FREED_CACHE=0
add_report "7️⃣ 패키지 캐시: $(gb "$FREED_CACHE") 확보"

# -------------------------------------------------------
# 8. /var snap/시스템 캐시 정리
# -------------------------------------------------------
log "[8/17] /var snap/시스템 캐시 정리"
VAR_CACHE_TARGETS=(
  /var/lib/snapd/cache
  /var/cache/snapd
  /var/cache/fwupd
  /var/cache/man
  /var/cache/cups
  /var/crash
  /var/tmp
  /var/backups
)
VAR_CACHE_BEFORE=$(sudo_du_bytes "${VAR_CACHE_TARGETS[@]}")

if command -v snap >/dev/null 2>&1; then
  while read -r SNAP_NAME SNAP_REV; do
    [[ -n "$SNAP_NAME" && -n "$SNAP_REV" ]] || continue
    sudo snap remove "$SNAP_NAME" --revision="$SNAP_REV" 2>/dev/null || true
  done < <(snap list --all 2>/dev/null | awk '/disabled|사용 불가/ {print $1, $3}')
fi

sudo find /var/lib/snapd/cache -mindepth 1 -maxdepth 1 -type f -delete 2>/dev/null || true
sudo find /var/cache/snapd -mindepth 1 -maxdepth 1 -delete 2>/dev/null || true
sudo find /var/cache/fwupd -mindepth 1 -maxdepth 1 -mtime +7 -delete 2>/dev/null || true
sudo find /var/cache/man -type f -mtime +30 -delete 2>/dev/null || true
sudo find /var/cache/cups -type f -mtime +14 -delete 2>/dev/null || true
sudo find /var/crash -mindepth 1 -type f -mtime +7 -delete 2>/dev/null || true
sudo find /var/tmp -mindepth 1 -type f -atime +7 -delete 2>/dev/null || true
sudo find /var/tmp -mindepth 1 -type d -empty -mtime +7 -delete 2>/dev/null || true
sudo find /var/backups -type f \( -name '*.gz' -o -name '*.old' -o -name '*.[0-9]' \) -mtime +30 -delete 2>/dev/null || true

VAR_CACHE_AFTER=$(sudo_du_bytes "${VAR_CACHE_TARGETS[@]}")
FREED_VAR_CACHE=$((${VAR_CACHE_BEFORE:-0} - ${VAR_CACHE_AFTER:-0}))
[ "$FREED_VAR_CACHE" -lt 0 ] && FREED_VAR_CACHE=0
add_report "8️⃣ /var snap/시스템 캐시: $(gb "$FREED_VAR_CACHE") 확보"

# -------------------------------------------------------
# 9. /opt 앱 캐시/로그 정리
# -------------------------------------------------------
log "[9/17] /opt 앱 캐시/로그 정리"
OPT_CACHE_TARGETS=(
  /opt
)
OPT_BEFORE=$(sudo_du_bytes "${OPT_CACHE_TARGETS[@]}")
while IFS= read -r -d '' OPT_CACHE_DIR; do
  sudo find "$OPT_CACHE_DIR" -mindepth 1 -mtime +7 -exec rm -rf -- {} + 2>/dev/null || true
done < <(sudo find /opt -xdev -type d \( -iname cache -o -iname caches -o -iname logs -o -iname log -o -iname tmp -o -iname temp \) \
  -not -path '/opt/rocm-*' \
  -not -path '/opt/amdgpu*' \
  -print0 2>/dev/null)
sudo find /opt -xdev -type f \( -name '*.log' -o -name '*.tmp' -o -name '*.old' \) \
  -not -path '/opt/rocm-*' \
  -not -path '/opt/amdgpu*' \
  -mtime +14 -delete 2>/dev/null || true
OPT_AFTER=$(sudo_du_bytes "${OPT_CACHE_TARGETS[@]}")
FREED_OPT=$((${OPT_BEFORE:-0} - ${OPT_AFTER:-0}))
[ "$FREED_OPT" -lt 0 ] && FREED_OPT=0
add_report "9️⃣ /opt 앱 캐시/로그: $(gb "$FREED_OPT") 확보"

# -------------------------------------------------------
# 10. /tmp 오래된 파일 정리 (7일 이상)
# -------------------------------------------------------
log "[10/17] /tmp 정리"
TMP_BEFORE=$(du_bytes /tmp)
find /tmp -type f -mtime +7 -not -path "/tmp/systemd-*" -delete 2>/dev/null || true
find /tmp -type d -empty -mtime +7 -not -path "/tmp" -delete 2>/dev/null || true
TMP_AFTER=$(du_bytes /tmp)
FREED_TMP=$((${TMP_BEFORE:-0} - ${TMP_AFTER:-0}))
[ "$FREED_TMP" -lt 0 ] && FREED_TMP=0
add_report "🔟 /tmp: $(gb "$FREED_TMP") 확보"

# -------------------------------------------------------
# 11. VSCode Server 캐시 정리
# -------------------------------------------------------
log "[11/17] VSCode Server 캐시 정리"
VSCODE_BEFORE=$(du -sb $HOME/.vscode-server/data/CachedExtensionVSIXs \
                        $HOME/.vscode-server/data/logs 2>/dev/null | awk '{s+=$1}END{print s+0}') || VSCODE_BEFORE=0
# 확장 설치 캐시 — VSCode가 필요 시 재다운로드하므로 안전하게 삭제
rm -rf $HOME/.vscode-server/data/CachedExtensionVSIXs/* 2>/dev/null || true
# 서버 로그 삭제
rm -rf $HOME/.vscode-server/data/logs/* 2>/dev/null || true
VSCODE_AFTER=$(du -sb $HOME/.vscode-server/data/CachedExtensionVSIXs \
                       $HOME/.vscode-server/data/logs 2>/dev/null | awk '{s+=$1}END{print s+0}') || VSCODE_AFTER=0
FREED_VSCODE=$((${VSCODE_BEFORE:-0} - ${VSCODE_AFTER:-0}))
[ "$FREED_VSCODE" -lt 0 ] && FREED_VSCODE=0
add_report "1️⃣1️⃣ VSCode 캐시: $(gb "$FREED_VSCODE") 확보"

# -------------------------------------------------------
# 12. 데스크톱 앱 캐시 정리 (VSCode, Freelens, Edge, Firefox snap)
# -------------------------------------------------------
log "[12/17] 데스크톱 앱 캐시 정리"
APP_CACHE_PATHS=(
  "$HOME/.config/Code/Cache"
  "$HOME/.config/Code/CachedData"
  "$HOME/.config/Code/CachedExtensionVSIXs"
  "$HOME/.config/Code/GPUCache"
  "$HOME/.config/Code/logs"
  "$HOME/.config/Freelens/Cache"
  "$HOME/.config/Freelens/GPUCache"
  "$HOME/.config/Freelens/logs"
  "$HOME/.config/microsoft-edge/ShaderCache"
  "$HOME/.config/microsoft-edge/GrShaderCache"
  "$HOME/.config/microsoft-edge/component_crx_cache"
  "$HOME/snap/firefox/common/.cache/mozilla"
)
APP_CACHE_BEFORE=$(du_bytes "${APP_CACHE_PATHS[@]}")
for CACHE_PATH in "${APP_CACHE_PATHS[@]}"; do
  empty_dir_contents "$CACHE_PATH"
done
APP_CACHE_AFTER=$(du_bytes "${APP_CACHE_PATHS[@]}")
FREED_APP_CACHE=$((${APP_CACHE_BEFORE:-0} - ${APP_CACHE_AFTER:-0}))
[ "$FREED_APP_CACHE" -lt 0 ] && FREED_APP_CACHE=0
add_report "1️⃣2️⃣ 데스크톱 앱 캐시: $(gb "$FREED_APP_CACHE") 확보"

# -------------------------------------------------------
# 13. 휴지통 비우기
# -------------------------------------------------------
log "[13/17] 휴지통 비우기"
TRASH_PATHS=(
  "$HOME/.local/share/Trash/files"
  "$HOME/.local/share/Trash/info"
)
TRASH_BEFORE=$(du_bytes "${TRASH_PATHS[@]}")
for TRASH_PATH in "${TRASH_PATHS[@]}"; do
  empty_dir_contents "$TRASH_PATH"
done
TRASH_AFTER=$(du_bytes "${TRASH_PATHS[@]}")
FREED_TRASH=$((${TRASH_BEFORE:-0} - ${TRASH_AFTER:-0}))
[ "$FREED_TRASH" -lt 0 ] && FREED_TRASH=0
add_report "1️⃣3️⃣ 휴지통: $(gb "$FREED_TRASH") 확보"

# -------------------------------------------------------
# 14. 오래된 VSCode Server 바이너리 정리
# -------------------------------------------------------
log "[14/17] 오래된 VSCode Server 바이너리 정리"
VSCODE_SERVER_DIR="$HOME/.vscode-server/cli/servers"
OLD_SERVER_BEFORE=$(du_bytes "$VSCODE_SERVER_DIR")
if [[ -d "$VSCODE_SERVER_DIR" ]]; then
  LATEST_SERVER=$(find "$VSCODE_SERVER_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
  while IFS= read -r SERVER_DIR; do
    [[ -n "$SERVER_DIR" && "$SERVER_DIR" != "$LATEST_SERVER" ]] || continue
    rm -rf -- "$SERVER_DIR" 2>/dev/null || true
  done < <(find "$VSCODE_SERVER_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +30 -print 2>/dev/null)
fi
OLD_SERVER_AFTER=$(du_bytes "$VSCODE_SERVER_DIR")
FREED_OLD_SERVER=$((${OLD_SERVER_BEFORE:-0} - ${OLD_SERVER_AFTER:-0}))
[ "$FREED_OLD_SERVER" -lt 0 ] && FREED_OLD_SERVER=0
add_report "1️⃣4️⃣ 오래된 VSCode Server: $(gb "$FREED_OLD_SERVER") 확보"

# -------------------------------------------------------
# 15. 홈 디렉토리 로그 찌꺼기 정리
# -------------------------------------------------------
log "[15/17] 홈 디렉토리 로그 찌꺼기 정리"
HOME_LOG_TARGETS=(
  "$HOME/.npm/_logs"
  "$HOME/.config/Termius/session-logs-v2"
  "$HOME/.config/VirtualBox"
  "$HOME/.local/share/xorg"
  "$HOME/.local/state"
  "$HOME/.minecraft/logs"
  "$HOME/snap/discord"
  "$HOME/snap/snap-store"
)
HOME_LOG_BEFORE=$(du_bytes "${HOME_LOG_TARGETS[@]}" "$HOME"/.xorgxrdp*.log "$HOME"/.xorgxrdp*.log.old)
find "$HOME/.npm/_logs" -xdev -type f -name '*.log' -mtime +14 -delete 2>/dev/null || true
find "$HOME/.config/Termius/session-logs-v2" -xdev -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
find "$HOME/.config/VirtualBox" -xdev -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.*' \) -mtime +30 -delete 2>/dev/null || true
find "$HOME/.local/share/xorg" -xdev -type f \( -name '*.log' -o -name '*.log.old' \) -mtime +30 -delete 2>/dev/null || true
find "$HOME/.local/state" -xdev -type f -name '*.log' -mtime +30 -delete 2>/dev/null || true
find "$HOME/.minecraft/logs" -xdev -type f \( -name '*.log' -o -name '*.log.gz' \) -mtime +30 -delete 2>/dev/null || true
find "$HOME/snap/discord" -xdev -path '*/.config/discord/logs/*.log' -type f -mtime +14 -delete 2>/dev/null || true
find "$HOME/snap/snap-store" -xdev -path '*/.local/share/snap-store/*.log*' -type f -mtime +30 -delete 2>/dev/null || true
find "$HOME" -xdev -maxdepth 1 -type f \( -name '.xorgxrdp*.log' -o -name '.xorgxrdp*.log.old' \) -mtime +30 -delete 2>/dev/null || true
HOME_LOG_AFTER=$(du_bytes "${HOME_LOG_TARGETS[@]}" "$HOME"/.xorgxrdp*.log "$HOME"/.xorgxrdp*.log.old)
FREED_HOME_LOGS=$((${HOME_LOG_BEFORE:-0} - ${HOME_LOG_AFTER:-0}))
[ "$FREED_HOME_LOGS" -lt 0 ] && FREED_HOME_LOGS=0
add_report "1️⃣5️⃣ 홈 로그 찌꺼기: $(gb "$FREED_HOME_LOGS") 확보"

# -------------------------------------------------------
# 16. 오래된 앱 백업 파일 정리
# -------------------------------------------------------
log "[16/17] 오래된 앱 백업 파일 정리"
APP_BACKUP_TARGETS=(
  "$HOME/.config/Code/User"
  "$HOME/.vscode-shared"
)
APP_BACKUP_BEFORE=$(du_bytes "${APP_BACKUP_TARGETS[@]}")
find "$HOME/.config/Code/User" "$HOME/.vscode-shared" -xdev -type f -name 'state.vscdb.backup' -mtime +30 -delete 2>/dev/null || true
APP_BACKUP_AFTER=$(du_bytes "${APP_BACKUP_TARGETS[@]}")
FREED_APP_BACKUPS=$((${APP_BACKUP_BEFORE:-0} - ${APP_BACKUP_AFTER:-0}))
[ "$FREED_APP_BACKUPS" -lt 0 ] && FREED_APP_BACKUPS=0
add_report "1️⃣6️⃣ 오래된 앱 백업: $(gb "$FREED_APP_BACKUPS") 확보"

# -------------------------------------------------------
# 17. 오래된 임시/편집기 찌꺼기 정리
# -------------------------------------------------------
log "[17/17] 오래된 임시/편집기 찌꺼기 정리"
CLUTTER_TARGETS=(
  "$HOME/다운로드"
  "$HOME/문서"
  "$HOME/.config/Freelens"
  "$HOME/.config/Code"
  "$HOME/.cache"
  "$HOME/.local/share/gvfs-metadata"
)
CLUTTER_BEFORE=$(du_bytes "${CLUTTER_TARGETS[@]}")
find "${CLUTTER_TARGETS[@]}" -xdev -type f -mtime +30 \
  \( -name '*~' -o -name '*.tmp' -o -name '*.swp' -o -name '*.swo' -o -name '*.rej' -o -name '.DS_Store' -o -name 'Thumbs.db' \) \
  -delete 2>/dev/null || true
find "$HOME/.config/Freelens" -xdev -maxdepth 1 -type f -name '.org.chromium.Chromium.*' -mtime +30 -delete 2>/dev/null || true
find "$HOME/.local/share/gvfs-metadata" -xdev -type f \( -name '*.log.*' -o -name '*.log.[A-Z0-9]*' \) -mtime +30 -delete 2>/dev/null || true
CLUTTER_AFTER=$(du_bytes "${CLUTTER_TARGETS[@]}")
FREED_CLUTTER=$((${CLUTTER_BEFORE:-0} - ${CLUTTER_AFTER:-0}))
[ "$FREED_CLUTTER" -lt 0 ] && FREED_CLUTTER=0
add_report "1️⃣7️⃣ 임시/편집기 찌꺼기: $(gb "$FREED_CLUTTER") 확보"

# --- 정리 후 현황 ---
AFTER=$(df_gb)
log "정리 후: $AFTER"
log "=== 디스크 정리 완료 ==="

add_report ""
add_report "📊 **정리 후**: $AFTER"

# --- 보고서 출력 (OpenClaw에서 파싱 가능) ---
echo ""
echo "========== CLEANUP REPORT =========="
echo -e "$REPORT"
echo "===================================="

DISCORD_MESSAGE=$(printf '디스크 정리 리포트 — %s\n%b' "$TIMESTAMP" "$REPORT")
send_discord_report "${CHANNEL_UPDATE:-}" "$DISCORD_MESSAGE"
