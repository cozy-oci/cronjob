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

# Exercise the report's actual dispatch so an unconditional send is caught.
for result in success error; do
    (
        LOG_FILE="$fixture/dispatch-$result.log"
        printf 'Error: previous run\n' > "$LOG_FILE"
        LOG_START=$(wc -c < "$LOG_FILE")
        if [[ "$result" == error ]]; then
            printf 'Error: download failed\n' >> "$LOG_FILE"
        else
            printf 'All updates completed\n' >> "$LOG_FILE"
        fi
        DNF_UPDATES='' BREW_UPDATES='' NPM_UPDATES=''
        source <(sed -n '/^empty_if_blank()/,/^}/p' "$script_dir/package-update.sh")
        send_discord_report() { printf '%s\n' "$2" >> "$fixture/sent-$result"; }
        source <(sed -n '/^DISCORD_MESSAGE=/,$p' "$script_dir/package-update.sh")
    )
done
if [[ -e "$fixture/sent-success" ]]; then
    echo 'FAIL: successful package update sent a Discord report' >&2
    exit 1
fi
[[ -s "$fixture/sent-error" ]]

cost_report="$script_dir/ubnutu/daily-oci-cost-report.sh"
source <(sed -n '/^should_notify_discord()/,/^}/p' "$cost_report")
for pair in '10 10' '19.99 10' '0 10' '10 0' '0 0'; do
    read -r current previous <<< "$pair"
    if should_notify_discord "$current" "$previous"; then
        echo "FAIL: unexpected cost alert: $pair" >&2
        exit 1
    fi
done
should_notify_discord 20 10
should_notify_discord 20.01 10
should_notify_discord 0.02 0.01

# Run the cost report at a month boundary with external services replaced.
mkdir "$fixture/discord-home"
cat > "$fixture/discord-home/.discord.env" <<'EOF'
export DISCORD_TOKEN=test-discord-token
export CHANNEL_COST=123
export CHANNEL_UPDATE=456
EOF
for current in 19.99 20; do
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
                printf 'FAIL: unexpected curl request from cost report\n' >&2
                return 1
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
        python3() {
            [[ "$1" == "$script_dir/ubnutu/../discord_notify.py" && "$2" == --channel &&
                "$3" == 123 && "$4" == -- && "$DISCORD_TOKEN" == test-discord-token ]] || return 1
            printf '%s\n' "$5" >> "$fixture/posts-$current"
        }
        export HOME="$fixture/discord-home"
        unset DISCORD_TOKEN CHANNEL_COST CHANNEL_PRICING CHANNEL_UPDATE
        source "$cost_report" > "$fixture/report-$current"
    )
done
[[ ! -e "$fixture/posts-19.99" ]]
grep -Fq 'OCI 일일 비용 리포트' "$fixture/posts-20"

# Exercise app updates with stand-ins for package managers and Discord.
mkdir "$fixture/bin" "$fixture/ubnutu"
sed "s|/home/linuxbrew/.linuxbrew/bin/brew|brew|; s|/home/ubuntu/.local/bin/codex|codex|" \
    "$script_dir/ubnutu/app-update.sh" > "$fixture/ubnutu/app-update.sh"
cat > "$fixture/bin/sudo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TRACE"
case "$1 $2" in
    'apt update')
        if [ "${APT_STATUS:-0}" -ne 0 ]; then
            echo 'E: Could not resolve packages.example.test' >&2
        fi
        exit "${APT_STATUS:-0}"
        ;;
    'snap refresh')
        if [ "${SNAP_STATUS:-0}" -ne 0 ]; then
            echo 'error: cannot reach https://demo:example-secret@store.example.test'
        fi
        exit "${SNAP_STATUS:-0}"
        ;;
esac
EOF
cat > "$fixture/bin/brew" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$fixture/bin/codex" <<'EOF'
#!/bin/sh
echo 'codex update' >> "$TRACE"
echo 'Codex is up to date'
EOF
cat > "$fixture/bin/python3" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >> "$TRACE.alert"
exit "${DISCORD_STATUS:-0}"
EOF
chmod +x "$fixture/bin/"*
update_app() (
    cd /
    export PATH="$fixture/bin:$PATH" TRACE="$fixture/app-$1"
    sh "$fixture/ubnutu/app-update.sh" > "$TRACE.stdout" 2> "$TRACE.stderr"
)
update_app success
[[ ! -e "$fixture/app-success.alert" ]]
grep -Fxq 'apt upgrade -y' "$fixture/app-success"
status=0
APT_STATUS=42 SNAP_STATUS=9 DISCORD_STATUS=3 update_app fail || status=$?
if [[ "$status" != 1 ]]; then
    echo "FAIL: failed app updates returned $status, expected 1" >&2
    exit 1
fi
[[ $(grep -Fxc "$fixture/ubnutu/../discord_notify.py" "$fixture/app-fail.alert") == 1 ]]
grep -Eq 'apt update.*42' "$fixture/app-fail.alert"
grep -Eq 'snap refresh.*9' "$fixture/app-fail.alert"
grep -Fq 'E: Could not resolve packages.example.test' "$fixture/app-fail.alert"
grep -Fq 'E: Could not resolve packages.example.test' "$fixture/app-fail.stderr"
grep -Fq 'error: cannot reach' "$fixture/app-fail.stdout"
grep -Fq 'error: cannot reach https://[redacted]@store.example.test' "$fixture/app-fail.alert"
if grep -Eq 'example-secret|Codex is up to date' "$fixture/app-fail.alert"; then
    echo 'FAIL: alert included credentials or output from a successful step' >&2
    exit 1
fi
grep -Fxq 'codex update' "$fixture/app-fail"
if grep -q 'apt upgrade' "$fixture/app-fail"; then
    echo 'FAIL: apt upgrade ran after apt update failed' >&2
    exit 1
fi


# Exercise only the Ubuntu cleanup report, without running any cleanup commands.
disk_cleanup="$script_dir/ubnutu/ubuntu-disk-cleanup.sh"
sed -n '/^load_discord_env()/,/^}/p; /^send_discord_report()/,/^}/p; /^DISCORD_MESSAGE=/,$p' \
    "$disk_cleanup" > "$fixture/ubnutu/disk-report.sh"
run_disk_report() (
    unset DISCORD_TOKEN CHANNEL_STATUS CHANNEL_UPDATE
    export HOME="$fixture/discord-home"
    TIMESTAMP=2026-11-21 REPORT='cleanup report fixture'
    log() { printf '%s\n' "$*" >&2; }
    curl() { echo 'FAIL: cleanup attempted a direct Discord request' >&2; return 1; }
    python3() {
        [[ "$1" == "$fixture/ubnutu/../discord_notify.py" && "$2" == --channel &&
            "$3" == 789 && "$4" == -- && "$DISCORD_TOKEN" == test-discord-token ]] || return 1
        printf '%s\n' "$5" >> "$fixture/disk-notification"
    }
    source "$fixture/ubnutu/disk-report.sh"
)
run_disk_report 2> "$fixture/disk-missing-status"
[[ ! -e "$fixture/disk-notification" ]]
grep -Fq "상태 채널 ID가 없어 전송을 건너뜀" "$fixture/disk-missing-status"
printf '%s\n' 'export CHANNEL_STATUS=789' >> "$fixture/discord-home/.discord.env"
run_disk_report
grep -Fq 'cleanup report fixture' "$fixture/disk-notification"

echo 'Discord notification checks passed'
