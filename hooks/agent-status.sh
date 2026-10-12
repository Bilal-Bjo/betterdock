#!/bin/sh
# Records an agent's state for BetterDock's status dots.
# Called by Claude Code / Codex hooks: agent-status.sh <agent> <working|done|attention|end>
# Hook input arrives on stdin as JSON; only session_id is read. Prints nothing.
agent="$1"
state="$2"
input=$(cat)
session=$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
[ -n "$session" ] || session="default"

dir="$HOME/Library/Application Support/BetterDock/agents"
mkdir -p "$dir"
file="$dir/$agent-$session.json"

if [ "$state" = "end" ]; then
  rm -f "$file"
  exit 0
fi

# __CFBundleIdentifier names the app the agent runs in (Claude, Terminal, cmux…): the dot goes on that icon.
printf '{"agent":"%s","state":"%s","bundle":"%s","updated":%s}\n' \
  "$agent" "$state" "${__CFBundleIdentifier:-}" "$(date +%s)" > "$file.tmp" && mv "$file.tmp" "$file"
exit 0
