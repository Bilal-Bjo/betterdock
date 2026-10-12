#!/bin/zsh
# Adds BetterDock's status hooks to Claude Code (~/.claude/settings.json) and Codex (~/.codex/hooks.json).
# Existing hooks are kept; running it twice changes nothing. Backups are written next to each file.
set -euo pipefail
script="$(cd "$(dirname "$0")" && pwd)/agent-status.sh"
chmod +x "$script"

/usr/bin/python3 - "$script" <<'PY'
import json, os, shutil, sys
script = sys.argv[1]

def add(path, agent, events):
    if not os.path.exists(os.path.dirname(path)):
        return
    data = json.load(open(path)) if os.path.exists(path) else {}
    if os.path.exists(path):
        shutil.copy(path, path + ".betterdock.bak")
    hooks = data.setdefault("hooks", {})
    for event, state in events.items():
        command = f"'{script}' {agent} {state}"
        groups = hooks.setdefault(event, [])
        if any(h.get("command") == command for g in groups for h in g.get("hooks", [])):
            continue
        groups.append({"hooks": [{"type": "command", "command": command, "timeout": 5}]})
    json.dump(data, open(path, "w"), indent=2)
    print(f"updated {path}")

events = {"UserPromptSubmit": "working", "PostToolUse": "working",
          "PermissionRequest": "attention", "Stop": "done"}
add(os.path.expanduser("~/.claude/settings.json"), "claude", {**events, "SessionEnd": "end"})
add(os.path.expanduser("~/.codex/hooks.json"), "codex", events)
PY
echo "Done. Codex asks you to trust new hooks the next time it starts."
