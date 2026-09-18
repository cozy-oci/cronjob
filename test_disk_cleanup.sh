#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script="$script_dir/disk-cleanup.sh"

grep -Fq 'uv cache clean --cache-dir "$UV_CACHE_DIR"' "$script"
grep -Fq 'uv 캐시:' "$script"
