#!/usr/bin/env python3
"""Claude Code 훅 설정 도우미.

  python3 scripts/hooks.py print > /tmp/notch-hooks.json   # claude --settings 로 임시 테스트
  python3 scripts/hooks.py install                          # ~/.claude/settings.json 에 추가 (백업 생성)
  python3 scripts/hooks.py uninstall                        # notch-bridge 훅만 제거
"""
import json
import shutil
import sys
import time
from pathlib import Path

SETTINGS = Path.home() / ".claude" / "settings.json"
COMMAND = '"$HOME/.notch-island/bin/notch-bridge" --source claude || true'
MARKER = "notch-bridge"

# 이벤트 → (matcher, timeout초)
EVENTS = {
    "SessionStart": (None, None),
    "SessionEnd": (None, None),
    "UserPromptSubmit": (None, None),
    "PreToolUse": ("*", None),
    "PostToolUse": ("*", None),
    "PermissionRequest": ("*", 86400),
    "Notification": ("*", None),
    "Stop": (None, None),
}


def hook_entries():
    hooks = {}
    for event, (matcher, timeout) in EVENTS.items():
        hook = {"type": "command", "command": COMMAND}
        if timeout:
            hook["timeout"] = timeout
        entry = {"hooks": [hook]}
        if matcher:
            entry["matcher"] = matcher
        hooks[event] = [entry]
    return hooks


def strip_ours(settings):
    hooks = settings.get("hooks", {})
    for event in list(hooks):
        kept = []
        for entry in hooks[event]:
            entry["hooks"] = [h for h in entry.get("hooks", []) if MARKER not in h.get("command", "")]
            if entry["hooks"]:
                kept.append(entry)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
    return settings


def load():
    return json.loads(SETTINGS.read_text()) if SETTINGS.exists() else {}


def save(settings):
    if SETTINGS.exists():
        backup = SETTINGS.with_name(f"settings.json.bak-{int(time.time())}")
        shutil.copy2(SETTINGS, backup)
        print(f"백업: {backup}")
    SETTINGS.parent.mkdir(parents=True, exist_ok=True)
    SETTINGS.write_text(json.dumps(settings, indent=2, ensure_ascii=False) + "\n")


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "print"
    if cmd == "print":
        print(json.dumps({"hooks": hook_entries()}, indent=2))
    elif cmd == "install":
        settings = strip_ours(load())
        hooks = settings.setdefault("hooks", {})
        for event, entries in hook_entries().items():
            hooks.setdefault(event, []).extend(entries)
        save(settings)
        print(f"설치 완료: {SETTINGS}")
    elif cmd == "uninstall":
        save(strip_ours(load()))
        print(f"제거 완료: {SETTINGS}")
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
