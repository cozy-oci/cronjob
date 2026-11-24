#!/bin/sh

log_dir=$(mktemp -d) || exit 1
trap 'rm -rf -- "$log_dir"' EXIT

failures=''
run_update() {
    status=0
    "$@" >"$log_dir/stdout" 2>"$log_dir/stderr" || status=$?
    cat "$log_dir/stdout"
    cat "$log_dir/stderr" >&2
    if [ "$status" -eq 0 ]; then
        return 0
    fi

    printf '[app-update] %s 실패 (종료 코드 %s)\n' "$*" "$status" >&2
    details=$(tail -qn 6 "$log_dir/stdout" "$log_dir/stderr" | tail -n 6 |
        LC_ALL=C.UTF-8 sed -E '/^[[:space:]]*$/d
            s#(https?://)[^/@[:space:]]+@#\1[redacted]@#g
            s/(Authorization:[[:space:]]*(Bearer|Bot|Basic)[[:space:]]+)[^[:space:]]+/\1[redacted]/Ig
            s/^(.{160}).+$/\1…/
            s/^/> /')
    failures="${failures}
- $* 실패 (종료 코드 $status)${details:+
$details}"
    return "$status"
}

update_codex() {
    curl -fsSL --output "$log_dir/codex-install.sh" https://chatgpt.com/codex/install.sh &&
        sh "$log_dir/codex-install.sh"
}

run_update sudo apt update -y && run_update sudo apt upgrade -y
run_update /home/linuxbrew/.linuxbrew/bin/brew upgrade --no-ask
run_update sudo snap refresh
run_update update_codex

if [ -n "$failures" ]; then
    if ! python3 "$(dirname -- "$0")/../discord_notify.py" -- "[$(uname -n)] 앱 업데이트 실패$failures"; then
        printf '[app-update] Discord 알림 전송 실패\n' >&2
    fi
    exit 1
fi
