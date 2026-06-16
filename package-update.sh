#!/usr/bin/env bash
# cronjob 등록 예시:
#   0 4 * * * /app/cozy-oci/cronjob/package-update.sh >> /tmp/package-update-$(date +\%Y\%m\%d).log 2>&1

set -euo pipefail

# 크론잡은 최소 PATH로 실행되므로 필요한 경로를 명시적으로 추가
export PATH="/home/opc/bin:/home/opc/.local/bin:/home/opc/.nvm/versions/node/v24.13.0/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin:$PATH"

# nvm 로드 후 관리 중인 npm 사용 (시스템 npm은 /usr/lib/node_modules에 root 권한 필요)
export NVM_DIR="/home/opc/.nvm"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

LOG_FILE="/tmp/package-update-$(date +%Y%m%d).log"
SEPARATOR="============================================================"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

load_discord_env() {
    if [[ -z "${DISCORD_TOKEN:-}" || -z "${CHANNEL_UPDATE:-}" ]]; then
        # cron does not load interactive shell config by default.
        # Import only Discord exports because .zshrc may contain zsh-only syntax.
        # shellcheck source=/dev/null
        [[ -r /home/opc/.park_reserve.env ]] && source <(grep -E '^export DISCORD_TOKEN=' /home/opc/.park_reserve.env) || true
        # shellcheck source=/dev/null
        [[ -r /home/opc/.zshrc ]] && source <(grep -E '^export (DISCORD_TOKEN|CHANNEL_UPDATE)=' /home/opc/.zshrc) || true
    fi
}

send_discord_report() {
    local channel="${1:-}"
    local message="$2"
    local chunk=""
    local line

    load_discord_env
    channel="${channel:-${CHANNEL_UPDATE:-}}"

    if [[ -z "${DISCORD_TOKEN:-}" || -z "$channel" ]]; then
        log "[Discord] DISCORD_TOKEN 또는 채널 ID가 없어 전송을 건너뜀"
        return 0
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        if (( ${#chunk} + ${#line} + 1 > 1900 )); then
            post_discord_message "$channel" "$chunk"
            chunk=""
        fi
        chunk+="${line}"$'\n'
    done <<< "$message"

    [[ -n "$chunk" ]] && post_discord_message "$channel" "$chunk"
}

post_discord_message() {
    local channel="$1"
    local message="$2"

    if ! curl -fsS -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
        -H "Authorization: Bot ${DISCORD_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg msg "$message" '{content:$msg}')" >/dev/null; then
        log "[Discord] 리포트 전송 실패"
    fi
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

format_dnf_output() {
    local file="$1"

    if grep -q '^Error:' "$file"; then
        awk '
            /^Error:/ { capture=1; print "- " $0; next }
            capture && (/^ Problem / || /^  - / || /^\(/) {
                line=$0
                sub(/^[[:space:]]+/, "", line)
                print "- " line
            }
        ' "$file" | head -20
        return 0
    fi

    awk '
        /^(Upgraded|Installed|Removed|Downgraded):$/ {
            section=$1
            sub(/:$/, "", section)
            next
        }
        section && /^[[:space:]]*$/ { section=""; next }
        section && NF >= 1 {
            printf "- %s %s\n", section, $1
        }
    ' "$file" | head -40
}

format_brew_updates() {
    { brew outdated --json=v2 2>/dev/null || true; } \
        | jq -r '
            [.formulae[]? | "- \(.name): \(.installed_versions | join(", ")) -> \(.current_version)"] +
            [.casks[]? | "- \(.name): \(.installed_versions | join(", ")) -> \(.current_version)"]
            | .[]
        ' | head -40
}

format_npm_updates() {
    { npm outdated -g --json 2>/dev/null || true; } \
        | jq -r '
            to_entries[]
            | "- \(.key): \(.value.current // "unknown") -> \(.value.wanted // .value.latest // "unknown") (latest: \(.value.latest // "unknown"))"
        ' | head -40
}

empty_if_blank() {
    local text="$1"
    if [[ -z "$text" ]]; then
        echo "- 업데이트 대상 없음"
    else
        printf '%s\n' "$text"
    fi
}

log "$SEPARATOR"
log "패키지 업데이트 시작"
log "$SEPARATOR"

log "업데이트 대상 수집 시작"
BREW_UPDATES=$(format_brew_updates)
NPM_UPDATES=$(format_npm_updates)
log "업데이트 대상 수집 완료"

# ── dnf update ──────────────────────────────────────────────
log "[1/3] dnf update 시작"
DNF_LOG="$TMP_DIR/dnf-update.log"
if sudo dnf update -y > "$DNF_LOG" 2>&1; then
    DNF_RESULT="완료"
    cat "$DNF_LOG" >> "$LOG_FILE"
    log "[1/3] dnf update 완료"
else
    DNF_RESULT="실패 (exit code: $?)"
    cat "$DNF_LOG" >> "$LOG_FILE"
    log "[1/3] dnf update $DNF_RESULT"
fi
DNF_UPDATES=$(format_dnf_output "$DNF_LOG")

# ── brew upgrade ─────────────────────────────────────────────
log "[2/3] brew upgrade 시작"
if brew upgrade >> "$LOG_FILE" 2>&1; then
    BREW_RESULT="완료"
    log "[2/3] brew upgrade 완료"
else
    BREW_RESULT="실패 (exit code: $?)"
    log "[2/3] brew upgrade $BREW_RESULT"
fi

# ── npm update -g ─────────────────────────────────────────────
log "[3/3] npm update -g 시작"
# Clear stale cache & openclaw/dist to fix ENOTEMPTY exit 217
npm cache clean --force 2>/dev/null
rm -rf /home/opc/.nvm/versions/node/v24.13.0/lib/node_modules/openclaw/dist 2>/dev/null
if npm update -g >> "$LOG_FILE" 2>&1; then
    NPM_RESULT="완료"
    log "[3/3] npm update -g 완료"
else
    NPM_RESULT="실패 (exit code: $?)"
    log "[3/3] npm update -g $NPM_RESULT"
fi

log "$SEPARATOR"
log "패키지 업데이트 완료 → 로그: $LOG_FILE"
log "$SEPARATOR"

DISCORD_MESSAGE=$(cat <<EOF
패키지 업데이트 리포트 — $(date '+%Y-%m-%d %H:%M KST')

dnf update: ${DNF_RESULT:-확인 불가}
$(empty_if_blank "$DNF_UPDATES")

brew upgrade: ${BREW_RESULT:-확인 불가}
$(empty_if_blank "$BREW_UPDATES")

npm update -g: ${NPM_RESULT:-확인 불가}
$(empty_if_blank "$NPM_UPDATES")

로그: $LOG_FILE
EOF
)
send_discord_report "${CHANNEL_UPDATE:-}" "$DISCORD_MESSAGE"
