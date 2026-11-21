#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$script_dir/disk-cleanup.sh"

grep -Fq 'uv cache clean --cache-dir "$UV_CACHE_DIR"' "$script"
grep -Fq 'uv 캐시:' "$script"

# Exercise the real helpers without running the scheduled cleanup actions.
source <(sed -n '/^format_disk_usage()/,/^}/p' "$script")
source <(sed -n '/^prune_obsolete_vscode_extensions()/,/^}/p' "$script")

actual=$(printf 'Used Avail Use%%\n36690500000 8857020000 81%%\n' | format_disk_usage)
[[ "$actual" == '사용 36.7GB · 여유 8.9GB · 사용률 81%' ]]

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/old-extension" "$fixture/current-extension" "$fixture/unmarked-extension"
printf '{"old-extension":true,"current-extension":true,"unmarked-extension":false,"../unsafe":true}\n' > "$fixture/.obsolete"
printf '[{"relativeLocation":"current-extension"}]\n' > "$fixture/extensions.json"
prune_obsolete_vscode_extensions "$fixture"
[[ ! -e "$fixture/old-extension" ]]
[[ -d "$fixture/current-extension" ]]
[[ -d "$fixture/unmarked-extension" ]]
