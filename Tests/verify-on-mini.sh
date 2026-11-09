#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
[[ -d /Volumes/DevVault/Dev ]] || { echo 'Native checks must run on the Mac mini with DevVault mounted.' >&2; exit 1; }
base="/Volumes/DevVault/Dev/betterdock-verification"
export TMPDIR="$base/tmp"
mkdir -p "$TMPDIR" "$base/build"
digest=$(python3 "$root/Tests/candidate-digest.py")
if [[ ! -x "$base/build/BetterDock" || ! -f "$base/build/source.sha256" || $(cat "$base/build/source.sha256") != "$digest" ]]; then
    xcrun swiftc -D BETTERDOCK_TESTS -O -target arm64-apple-macos14.0 -module-cache-path "$base/build/modules" \
      -o "$base/build/BetterDock" "$root"/Sources/Shared/*.swift "$root"/Sources/DockApp/*.swift "$root/Tests/NativeTests.swift"
    print "$digest" > "$base/build/source.sha256"
fi
[[ "${1:-}" == --build-only ]] && exit 0
# Only the small executable and fixtures stage internally: GUI launchd cannot read removable storage on this Mini.
job=$(mktemp -d /tmp/betterdock-verification.XXXXXX)
trap 'rm -rf "$job"' EXIT
mkdir -p "$job/BetterDock.app/Contents/MacOS"
cp "$base/build/BetterDock" "$job/BetterDock.app/Contents/MacOS/"
cp -R "$root/examples" "$job/examples"
cat > "$job/BetterDock.app/Contents/Info.plist" <<PLIST
<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.betterdock.verification</string>
<key>CFBundleExecutable</key><string>BetterDock</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$job/BetterDock.app"
"$root/release/mini-gui-run.sh" "$job" "$root/Tests/gui-job.sh" "$job"
