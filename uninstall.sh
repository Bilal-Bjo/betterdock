#!/bin/zsh
# Stop BetterDock, remove it from login, and bring Apple's Dock back exactly as it was.
cd "$(dirname "$0")"
label="com.betterdock.app"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/BetterDock.app"
pkill -x BetterDock 2>/dev/null || true
if [[ -f config/apple-dock-backup.plist ]]; then
  defaults import com.apple.dock config/apple-dock-backup.plist
  rm config/apple-dock-backup.plist
else
  defaults delete com.apple.dock autohide-delay 2>/dev/null || true
fi
killall Dock
echo "BetterDock removed. Apple's Dock is back as it was."
