#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$script_dir/mac-disk-cleanup.sh"

eval "$(sed -n '/^df_gb()/,/^}/p' "$script")"
eval "$(sed -n '/^size_to_gb()/,/^}/p' "$script")"
eval "$(sed -n '/^prune_general_cache()/,/^}/p' "$script")"
eval "$(sed -n '/^empty_trash()/,/^}/p' "$script")"

# The data volume under HOME must be measured, not macOS's sealed root volume.
df() {
  [[ "$1" == -Pk && "$2" == "$HOME" ]]
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
  printf '/dev/disk3s5 11718750 9765625 1953125 83%% /System/Volumes/Data\n'
}
[[ "$(df_gb)" == '사용 10.0GB · 여유 2.0GB · 사용률 83%' ]]
[[ "$(size_to_gb '5000MB')" == '5.0GB' ]]
[[ "$(size_to_gb '1GiB')" == '1.1GB' ]]

# A stale model blob and uv archive must survive generic cache pruning.
fixture=$(mktemp -d)
trap 'sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture"' EXIT
mkdir -p "$fixture/cache/huggingface/hub" "$fixture/cache/uv/archive-v0" "$fixture/cache/ordinary"
touch "$fixture/cache/huggingface/hub/model" "$fixture/cache/uv/archive-v0/wheel" "$fixture/cache/ordinary/old"
touch -a -t 202001010000 "$fixture/cache/huggingface/hub/model" "$fixture/cache/uv/archive-v0/wheel" "$fixture/cache/ordinary/old"
prune_general_cache "$fixture/cache"
[[ -f "$fixture/cache/huggingface/hub/model" ]]
[[ -f "$fixture/cache/uv/archive-v0/wheel" ]]
[[ ! -e "$fixture/cache/ordinary/old" ]]

mkdir -p "$fixture/trash/ordinary"
if [[ "$(uname -s)" == Darwin ]] && sudo -n true 2>/dev/null; then
  sudo -n mkdir "$fixture/trash/root-owned"
fi
empty_trash "$fixture/trash"
[[ ! -e "$fixture/trash/ordinary" ]]
[[ ! -e "$fixture/trash/root-owned" ]]
