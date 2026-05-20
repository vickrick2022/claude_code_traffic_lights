#!/usr/bin/env python3
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


VALID = {"idle", "running", "needs_confirmation"}


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: write_status.py <idle|running|needs_confirmation>", file=sys.stderr)
        return 1

    state = sys.argv[1].strip().lower()
    if state not in VALID:
        print(f"不支持的状态: {state}", file=sys.stderr)
        return 1

    path = os.environ.get("CLAUDE_STATUS_FILE", "~/.claudecode/status.json")
    file_path = Path(path).expanduser()
    file_path.parent.mkdir(parents=True, exist_ok=True)

    payload = {
        "state": state,
        "updatedAt": datetime.now(timezone.utc).isoformat(),
    }
    file_path.write_text(json.dumps(payload, ensure_ascii=True), encoding="utf-8")

    # 兼容 Hook 场景，输出允许继续执行。
    print(json.dumps({"permission": "allow"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
