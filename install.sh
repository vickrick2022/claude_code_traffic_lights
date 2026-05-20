#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SETTINGS_FILE="$HOME/.claude/settings.json"
HOOK_CMD="bash ${SCRIPT_DIR}/scripts/hook-status.sh"

if [ ! -f "$SETTINGS_FILE" ]; then
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  echo '{}' > "$SETTINGS_FILE"
fi

# Use python3 to safely merge hooks into settings.json
python3 - "$SETTINGS_FILE" "$HOOK_CMD" <<'PYTHON'
import json
import sys

settings_path = sys.argv[1]
hook_cmd = sys.argv[2]

with open(settings_path, "r") as f:
    settings = json.load(f)

hooks = settings.setdefault("hooks", {})

def add_hook(event, state, matcher=None):
    """Add a status glow hook to an event, avoiding duplicates."""
    cmd = f"{hook_cmd} {state}"
    groups = hooks.setdefault(event, [])

    # Check if already installed
    for group in groups:
        for h in group.get("hooks", []):
            if hook_cmd in h.get("command", ""):
                print(f"  跳过 {event} → {state} (已安装)")
                return

    entry = {"type": "command", "command": cmd, "timeout": 5}
    group = {"hooks": [entry]}
    if matcher:
        group["matcher"] = matcher
    groups.append(group)
    print(f"  添加 {event} → {state}")

print("正在配置 Claude Code hooks...")
add_hook("UserPromptSubmit", "running")
add_hook("PreToolUse", "needs_confirmation")
add_hook("PostToolUse", "running")
add_hook("Stop", "idle")

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)

print("\n✓ hooks 已写入 " + settings_path)
print("\n状态映射:")
print("  UserPromptSubmit → running (黄色)")
print("  PreToolUse       → needs_confirmation (红色)")
print("  PostToolUse      → running (黄色)")
print("  Stop             → idle (绿色)")
print("\n请确保光圈应用正在运行: swift run")
PYTHON
