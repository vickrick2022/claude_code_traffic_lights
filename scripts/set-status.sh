#!/bin/bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "用法: ./scripts/set-status.sh <idle|running|needs_confirmation>"
  exit 1
fi

python3 "$(dirname "$0")/write_status.py" "$1" >/dev/null
echo "状态已设置为: $1"
