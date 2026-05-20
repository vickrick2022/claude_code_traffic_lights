#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_CMD="bash ${SCRIPT_DIR}/scripts/hook-status.sh"

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "无需卸载: $SETTINGS_FILE 不存在"
  exit 0
fi

python3 - "$SETTINGS_FILE" "$HOOK_CMD" <<'PYTHON'
import json
import sys

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]

with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.get("hooks", {})
removed = 0

for event in list(hooks.keys()):
    groups = hooks[event]
    new_groups = []
    for group in groups:
        hook_list = group.get("hooks", [])
        filtered = [h for h in hook_list if hook_cmd not in h.get("command", "")]
        if filtered:
            group["hooks"] = filtered
            new_groups.append(group)
        else:
            removed += 1
    hooks[event] = new_groups
    if not new_groups:
        del hooks[event]

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print(f"✓ 已移除 {removed} 个 status glow hooks")
PYTHON
