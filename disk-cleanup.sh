#!/bin/bash
# ============================================================
# disk-cleanup.sh — Gateway 서버 디스크 정리 스크립트
# ============================================================
# 용도: 주기적 디스크 정리 (OpenClaw cron 또는 OS crontab)
# 대상: OCI ARM bastion (Oracle Linux 9)
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

# --- 정리 전 현황 ---
BEFORE=$(df / --output=used,avail,pcent | tail -1 | xargs)
log "=== 디스크 정리 시작 ($TIMESTAMP) ==="
log "정리 전: $BEFORE"
add_report "📊 **정리 전**: $BEFORE"

# -------------------------------------------------------
# 1. 시스템 로그 정리
# -------------------------------------------------------
log "[1/9] 시스템 로그 정리"
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

# messages, secure, xrdp.log, cron — 50MB 초과 시 truncate
for LOGFILE in /var/log/messages /var/log/secure /var/log/xrdp.log /var/log/cron; do
  if [ -f "$LOGFILE" ]; then
    SIZE=$(sudo stat -c%s "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$SIZE" -gt 52428800 ]; then  # 50MB
      FREED_LOG=$((FREED_LOG + SIZE))
      sudo truncate -s 0 "$LOGFILE"
      log "  truncated $LOGFILE ($(numfmt --to=iec $SIZE))"
    fi
  fi
done

add_report "1️⃣ 시스템 로그: $(numfmt --to=iec $FREED_LOG) 확보"

# -------------------------------------------------------
# 2. journald 로그 정리 (7일 보관)
# -------------------------------------------------------
log "[2/9] journald 정리"
JOURNAL_BEFORE=$(sudo journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
sudo journalctl --vacuum-time=7d --quiet 2>/dev/null || true
JOURNAL_AFTER=$(sudo journalctl --disk-usage 2>/dev/null | grep -oP '[\d.]+[KMGT]' || echo "0")
add_report "2️⃣ journald: ${JOURNAL_BEFORE} → ${JOURNAL_AFTER}"

# -------------------------------------------------------
# 3. dnf autoremove (불필요 패키지 제거) — clean all 전에 먼저 실행
# -------------------------------------------------------
log "[3/9] dnf autoremove"
AUTOREMOVE_OUTPUT=$(sudo dnf autoremove -y 2>/dev/null | grep -E "^Freed space:|^Nothing to do") || AUTOREMOVE_OUTPUT="Nothing to do"
add_report "3️⃣ dnf autoremove: ${AUTOREMOVE_OUTPUT}"

# -------------------------------------------------------
# 4. npm 캐시 정리
# -------------------------------------------------------
log "[4/9] npm 캐시 정리"
NPM_BEFORE=$(du -sb $HOME/.npm/_cacache $HOME/.npm/_npx 2>/dev/null | awk '{s+=$1}END{print s+0}') || NPM_BEFORE=0
$HOME/.nvm/versions/node/v24.13.0/bin/npm cache clean --force --silent 2>/dev/null || true
rm -rf $HOME/.npm/_npx 2>/dev/null || true
NPM_AFTER=$(du -sb $HOME/.npm/_cacache $HOME/.npm/_npx 2>/dev/null | awk '{s+=$1}END{print s+0}') || NPM_AFTER=0
FREED_NPM=$((${NPM_BEFORE:-0} - ${NPM_AFTER:-0}))
[ "$FREED_NPM" -lt 0 ] && FREED_NPM=0
add_report "4️⃣ npm 캐시(_cacache+_npx): $(numfmt --to=iec $FREED_NPM) 확보"

# -------------------------------------------------------
# 5. 유저 캐시 정리 (Homebrew, mozilla, pip)
# -------------------------------------------------------
log "[5/9] 유저 캐시 정리"
USER_BEFORE=$(du_bytes $HOME/.cache)
rm -rf $HOME/.cache/Homebrew/* 2>/dev/null || true
rm -rf $HOME/.cache/mozilla/* 2>/dev/null || true
rm -rf $HOME/.cache/pip/* 2>/dev/null || true
rm -rf $HOME/.cache/node-gyp/* 2>/dev/null || true
rm -rf $HOME/.cache/bbrew/* 2>/dev/null || true
rm -rf $HOME/.cache/helm/* 2>/dev/null || true
rm -rf $HOME/.cache/gnome-software/* 2>/dev/null || true
USER_AFTER=$(du_bytes $HOME/.cache)
FREED_USER=$((${USER_BEFORE:-0} - ${USER_AFTER:-0}))
[ "$FREED_USER" -lt 0 ] && FREED_USER=0
add_report "5️⃣ 유저 캐시: $(numfmt --to=iec $FREED_USER) 확보"

# -------------------------------------------------------
# 6. Docker 미사용 이미지 정리
# -------------------------------------------------------
log "[6/9] Docker 미사용 이미지 정리"
DOCKER_BEFORE=$(docker system df --format '{{.Size}}' 2>/dev/null | head -1 || echo "0")
DOCKER_OUTPUT=$(docker system prune -a -f 2>/dev/null | tail -1 || echo "Total reclaimed space: 0B")
DOCKER_FREED=$(echo "$DOCKER_OUTPUT" | grep -oP '[\d.]+\s*[KMGT]?B' || echo "0B")
add_report "6️⃣ Docker 정리: ${DOCKER_FREED} 확보"

# -------------------------------------------------------
# 7. 패키지 캐시 정리 (dnf + PackageKit) — autoremove 후 마지막에 정리
# -------------------------------------------------------
log "[7/9] 패키지 캐시 정리"
CACHE_BEFORE=$(sudo du -sb /var/cache/dnf /var/cache/PackageKit 2>/dev/null | awk '{s+=$1}END{print s+0}')
sudo dnf clean all --quiet 2>/dev/null || true
sudo rm -rf /var/cache/PackageKit/* 2>/dev/null || true
CACHE_AFTER=$(sudo du -sb /var/cache/dnf /var/cache/PackageKit 2>/dev/null | awk '{s+=$1}END{print s+0}')
FREED_CACHE=$((CACHE_BEFORE - CACHE_AFTER))
[ "$FREED_CACHE" -lt 0 ] && FREED_CACHE=0
add_report "7️⃣ 패키지 캐시: $(numfmt --to=iec $FREED_CACHE) 확보"

# -------------------------------------------------------
# 8. /tmp 오래된 파일 정리 (7일 이상)
# -------------------------------------------------------
log "[8/9] /tmp 정리"
TMP_BEFORE=$(du_bytes /tmp)
find /tmp -type f -mtime +7 -not -path "/tmp/systemd-*" -delete 2>/dev/null || true
find /tmp -type d -empty -mtime +7 -not -path "/tmp" -delete 2>/dev/null || true
TMP_AFTER=$(du_bytes /tmp)
FREED_TMP=$((${TMP_BEFORE:-0} - ${TMP_AFTER:-0}))
[ "$FREED_TMP" -lt 0 ] && FREED_TMP=0
add_report "8️⃣ /tmp: $(numfmt --to=iec $FREED_TMP) 확보"

# -------------------------------------------------------
# 9. VSCode Server 캐시 정리
# -------------------------------------------------------
log "[9/9] VSCode Server 캐시 정리"
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
add_report "9️⃣ VSCode 캐시: $(numfmt --to=iec $FREED_VSCODE) 확보"

# --- 정리 후 현황 ---
AFTER=$(df / --output=used,avail,pcent | tail -1 | xargs)
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
