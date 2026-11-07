#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

# Exercise notification decisions without updating packages or calling external APIs.
source <(sed -n '/^should_notify_discord()/,/^}/p' "$script_dir/package-update.sh")
printf 'Error: previous run\n' > "$fixture/update.log"
offset=$(wc -c < "$fixture/update.log")
printf 'All updates completed\n' >> "$fixture/update.log"
if should_notify_discord "$fixture/update.log" "$offset"; then
    echo 'FAIL: successful run or previous errors triggered notification' >&2
    exit 1
fi
for message in 'Error: download' 'npm ERR! network' 'FAILED to update' 'failure: download' '업데이트 실패' '에러 발생' '오류 발생'; do
    printf '%s\n' "$message" > "$fixture/update.log"
    should_notify_discord "$fixture/update.log" 0
done
# A package name containing "error" is not itself an error message.
printf 'Upgraded: libgpg-error\n' > "$fixture/update.log"
if should_notify_discord "$fixture/update.log" 0; then
    echo 'FAIL: package name triggered notification' >&2
    exit 1
fi

source <(sed -n '/^should_notify_discord()/,/^}/p' "$script_dir/daily-oci-cost-report.sh")
for pair in '10 10' '20 10' '29.99 10' '0 10' '10 0' '0 0'; do
    read -r current previous <<< "$pair"
    if should_notify_discord "$current" "$previous"; then
        echo "FAIL: unexpected cost alert: $pair" >&2
        exit 1
    fi
done
should_notify_discord 30 10
should_notify_discord 30.01 10
should_notify_discord 0.03 0.01

# Run the cost report at a month boundary with external services replaced.
for current in 29.99 30; do
    (
        date() {
            case "$*" in
                '+%Y-%m-%d') echo 2026-11-02 ;;
                '-d yesterday +%Y-%m-%d') echo 2026-11-01 ;;
                '-d 2 days ago +%Y-%m-%d') echo 2026-10-31 ;;
                '+%Y-%m-01') echo 2026-11-01 ;;
                *) echo '2026-11-02 04:00 KST' ;;
            esac
        }
        curl() {
            if [[ "$*" == *'https://open.er-api.com/'* ]]; then
                echo '{"rates":{"KRW":1100}}'
            else
                printf '%s\n' "$*" >> "$fixture/posts-$current"
            fi
        }
        oci() {
            local start='' end=''
            while (( $# )); do
                case "$1" in
                    --time-usage-started) start="$2"; shift ;;
                    --time-usage-ended) end="$2"; shift ;;
                esac
                shift
            done
            if [[ "$start $end" == '2026-10-31 2026-11-01' ]]; then
                echo '{"data":{"items":[{"computed-amount":10,"time-usage-started":"2026-10-31T00:00:00+00:00"}]}}'
            elif [[ "$start $end" == '2026-11-01 2026-11-02' ]]; then
                jq -n --argjson amount "$current" '{data:{items:[{"computed-amount":$amount,"time-usage-started":"2026-11-01T00:00:00+00:00"}]}}'
            else
                return 1
            fi
        }
        export DISCORD_TOKEN=test CHANNEL_PRICING=test
        source "$script_dir/daily-oci-cost-report.sh" > "$fixture/report-$current"
    )
done
[[ ! -e "$fixture/posts-29.99" ]]
[[ -s "$fixture/posts-30" ]]
echo 'Discord notification checks passed'
