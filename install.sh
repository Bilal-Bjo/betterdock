#!/bin/zsh
# Build BetterDock and install it.
#   ./install.sh          install to ~/Applications, start at login, hide Apple's Dock
#   ./install.sh --try    build and run once; nothing is installed and Apple's Dock is untouched
set -euo pipefail
cd "$(dirname "$0")"

name="BetterDock"
label="com.betterdock.app"
build="build"
app="$build/$name.app"
dest="$HOME/Applications/$name.app"

# First run: start from the example configuration.
if [[ ! -f config/dock.json ]]; then
  mkdir -p config/folders
  cp examples/dock.json config/dock.json
  cp examples/folders/*.json config/folders/
fi

rm -rf "$app" && mkdir -p "$app/Contents/MacOS"
swiftc -O -target arm64-apple-macos14.0 -o "$app/Contents/MacOS/$name" Sources/Shared/*.swift Sources/DockApp/*.swift

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
  <key>BDConfigDir</key><string>$PWD/config</string>
</dict></plist>
PLIST

# Signing with a stable identity lets macOS remember the Accessibility permission across rebuilds.
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${identity:--}" "$app" >/dev/null

pkill -x "$name" 2>/dev/null || true

if [[ "${1:-}" == "--try" ]]; then
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

# Apple's Dock keeps running (Cmd-Tab, Mission Control) but never appears.
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
killall Dock

echo "BetterDock installed. Undo with ./uninstall.sh"
