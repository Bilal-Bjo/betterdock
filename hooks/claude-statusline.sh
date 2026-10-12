#!/bin/sh
# Claude Code status line: shows this week's usage and saves it for BetterDock's AI Usage widget.
# Claude Code pipes a JSON payload on stdin; rate_limits is only present on Pro/Max plans.
input=$(cat)
read_key() { printf '%s' "$input" | plutil -extract "$1" raw -o - - 2>/dev/null; }

week=$(read_key rate_limits.seven_day.used_percentage)
resets=$(read_key rate_limits.seven_day.resets_at)
model=$(read_key model.display_name)

if [ -n "$week" ]; then
  dir="$HOME/Library/Application Support/BetterDock/usage"
  mkdir -p "$dir"
  printf '{"weekly":%s,"resets":"%s","updated":%s}\n' "$week" "$resets" "$(date +%s)" > "$dir/claude.json.tmp" \
    && mv "$dir/claude.json.tmp" "$dir/claude.json"
  printf '%s · Week %.0f%%' "${model:-Claude}" "$week"
else
  printf '%s' "${model:-Claude}"
fi
