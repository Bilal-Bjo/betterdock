#!/bin/zsh
# Stop BetterDock, remove it from login, and bring Apple's Dock back.
label="com.betterdock.app"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
rm -rf "$HOME/Applications/BetterDock.app"
pkill -x BetterDock 2>/dev/null || true
defaults delete com.apple.dock autohide-delay 2>/dev/null || true
killall Dock
echo "BetterDock removed. Apple's Dock is back."
