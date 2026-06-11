#!/usr/bin/env bash
set -euo pipefail

export PATH="/home/opc/bin:/home/opc/.local/bin:/home/opc/.nvm/versions/node/v24.13.0/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:/usr/local/bin:/usr/bin:/bin:$PATH"

TENANT_ID="ocid1.tenancy.oc1..aaaaaaaahsnrg2djzni7cvjs7dbd5xadz2l6pr3hsz7fd677tp7ikdcduxea"

load_discord_env() {
    if [[ -z "${DISCORD_TOKEN:-}" || -z "${CHANNEL_PRICING:-}" ]]; then
        # cron does not load interactive shell config by default.
        # Import only Discord exports because .zshrc may contain zsh-only syntax.
        # shellcheck source=/dev/null
        [[ -r /home/opc/.park_reserve.env ]] && source <(grep -E '^export DISCORD_TOKEN=' /home/opc/.park_reserve.env) || true
        # shellcheck source=/dev/null
        [[ -r /home/opc/.zshrc ]] && source <(grep -E '^export (DISCORD_TOKEN|CHANNEL_PRICING)=' /home/opc/.zshrc) || true
    fi
}

send_discord_report() {
    local channel="${1:-}"
    local message="$2"

    load_discord_env
    channel="${channel:-${CHANNEL_PRICING:-}}"

    if [[ -z "${DISCORD_TOKEN:-}" || -z "$channel" ]]; then
        echo "[Discord] DISCORD_TOKEN 또는 채널 ID가 없어 전송을 건너뜀" >&2
        return 0
    fi

    if (( ${#message} > 1900 )); then
        message="${message:0:1850}"$'\n... (truncated)'
    fi

    curl -fsS -X POST "https://discord.com/api/v10/channels/${channel}/messages" \
        -H "Authorization: Bot ${DISCORD_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg msg "$message" '{content:$msg}')" >/dev/null \
        || echo "[Discord] 리포트 전송 실패" >&2
}

# 날짜 계산 (KST 기준)
TODAY=$(date +%Y-%m-%d)
YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
DAY_BEFORE_YESTERDAY=$(date -d "2 days ago" +%Y-%m-%d)
MONTH_START=$(date +%Y-%m-01)

# SGD → KRW 실시간 환율 조회
SGD_TO_KRW=$(curl -s "https://open.er-api.com/v6/latest/SGD" | jq '.rates.KRW')
if [[ -z "$SGD_TO_KRW" || "$SGD_TO_KRW" == "null" ]]; then
    echo "[경고] 환율 조회 실패, 고정 환율 1100 적용"
    SGD_TO_KRW=1100
fi

# SGD 금액 → KRW 변환 (원 단위 반올림)
to_krw() {
    printf "%.0f" "$(echo "$1 $SGD_TO_KRW" | awk '{printf "%.10f", $1 * $2}')"
}

# OCI usage API 호출 헬퍼
fetch_cost() {
    local start="$1"
    local end="$2"
    oci usage-api usage-summary request-summarized-usages \
        --tenant-id "$TENANT_ID" \
        --time-usage-started "$start" \
        --time-usage-ended "$end" \
        --granularity DAILY \
        --query-type COST \
        --is-aggregate-by-time false \
        2>/dev/null
}

# 1. 이번 달 1일 ~ 어제: 일별 데이터 수집
MONTHLY_JSON=$(fetch_cost "$MONTH_START" "$TODAY")

# 총합 (1일 ~ 어제)
MONTHLY_SUM=$(echo "$MONTHLY_JSON" | jq '[.data.items[]["computed-amount"]] | add // 0')

# 2. 1일 ~ 그저께: 평균
AVG_TO_DBY=$(echo "$MONTHLY_JSON" | jq --arg dby "${DAY_BEFORE_YESTERDAY}T00:00:00+00:00" '
    [.data.items[]
     | select(.["time-usage-started"] <= $dby)
     | .["computed-amount"]]
    | if length == 0 then 0
      else (add / length)
      end
')

# 3. 어제 사용금액
YESTERDAY_COST=$(echo "$MONTHLY_JSON" | jq --arg y "$YESTERDAY" '
    [.data.items[]
     | select(.["time-usage-started"] | startswith($y))
     | .["computed-amount"]]
    | add // 0
')

# KRW 환산
MONTHLY_SUM_KRW=$(to_krw "$MONTHLY_SUM")
AVG_TO_DBY_KRW=$(to_krw "$AVG_TO_DBY")
YESTERDAY_COST_KRW=$(to_krw "$YESTERDAY_COST")

# 리포트 출력
SEPARATOR="════════════════════════════════════════"
REPORT=$(
    echo "$SEPARATOR"
    echo "  OCI 일일 비용 리포트 — $(date '+%Y-%m-%d %H:%M KST')"
    echo "$SEPARATOR"
    printf "  기준 기간   : %s ~ %s\n" "$MONTH_START" "$YESTERDAY"
    printf "  적용 환율   : 1 SGD = %.2f 원\n" "$SGD_TO_KRW"
    echo ""
    printf "  %-26s %'15d 원\n" "이번달 누적 (1일~어제)"    "$MONTHLY_SUM_KRW"
    printf "  %-26s %'15d 원\n" "일평균 (1일~그저께)"        "$AVG_TO_DBY_KRW"
    printf "  %-26s %'15d 원\n" "어제 사용금액 ($YESTERDAY)" "$YESTERDAY_COST_KRW"
    echo "$SEPARATOR"
)

printf '%s\n' "$REPORT"
send_discord_report "${CHANNEL_PRICING:-}" "$REPORT"
