#!/bin/zsh
# Build BetterDock and install it.
#   ./install.sh          install to ~/Applications, start at login, hide Apple's Dock
#   ./install.sh --try    build and run once; nothing is installed and Apple's Dock is untouched
#   ./install.sh --dist   build a standalone build/BetterDock.app for /Applications (settings in Application Support)
set -euo pipefail
cd "$(dirname "$0")"

name="BetterDock"
label="com.betterdock.app"
build="build"
app="$build/$name.app"
dest="$HOME/Applications/$name.app"

mode="${1:-}"

# First run: start from the example configuration.
if [[ "$mode" != "--dist" && ! -f config/dock.json ]]; then
  mkdir -p config/folders
  cp examples/dock.json config/dock.json
  cp examples/folders/*.json config/folders/
fi

rm -rf "$app" && mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
swiftc -O -target arm64-apple-macos14.0 -o "$app/Contents/MacOS/$name" Sources/Shared/*.swift Sources/DockApp/*.swift
# A standalone app seeds ~/Library/Application Support/BetterDock from these on first launch.
cp -R examples "$app/Contents/Resources/examples"

# Developer builds read and write the repository's config/; standalone builds use Application Support.
configKey=""
[[ "$mode" == "--dist" ]] || configKey="<key>BDConfigDir</key><string>$PWD/config</string>"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$label</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next event in the Calendar widget.</string>
  <key>NSAppleEventsUsageDescription</key><string>Shows and controls what Spotify or Music is playing in the Now Playing widget.</string>
  $configKey
</dict></plist>
PLIST

# Signing with a stable identity lets macOS remember the Accessibility permission across rebuilds.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${identity:--}" "$app" >/dev/null

if [[ "$mode" == "--dist" ]]; then
  echo "Built $app. Sign it with your Developer ID, notarize it, and ship it in a DMG; it sets itself up on first launch."
  exit 0
fi

if [[ "$mode" == "--try" ]] && launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
  echo "BetterDock is already installed. Run ./install.sh to update it, or ./uninstall.sh first to try a build."
  exit 1
fi

pkill -x "$name" 2>/dev/null || true

if [[ "$mode" == "--try" ]]; then
  open "$app"
  echo "BetterDock is running. Push the cursor to the bottom edge to reveal it."
  exit 0
fi

rm -rf "$dest" && cp -R "$app" "$dest"

agent="$HOME/Library/LaunchAgents/$label.plist"
cat > "$agent" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$dest/Contents/MacOS/$name</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
AGENT
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$agent"

# Apple's Dock keeps running (Cmd-Tab, Mission Control) but never appears: it hides with a very long
# delay, and is made as small as possible for the few places macOS still shows it (Mission Control).
# Your original settings are saved first so ./uninstall.sh can restore them exactly.
mkdir -p config
[[ -f config/apple-dock-backup.plist ]] || defaults export com.apple.dock config/apple-dock-backup.plist
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
defaults write com.apple.dock tilesize -int 16
defaults write com.apple.dock magnification -bool false
defaults write com.apple.dock launchanim -bool false
defaults write com.apple.dock show-recents -bool false
killall Dock

echo "BetterDock installed. Undo with ./uninstall.sh"
