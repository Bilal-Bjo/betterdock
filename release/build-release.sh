#!/bin/zsh
# Builds a release of BetterDock on the Mac mini.
#
#   release/build-release.sh <version> [--unsigned]
#
#   <version>     X.Y.Z, used for CFBundleShortVersionString and CFBundleVersion
#   --unsigned    dry run: build, bundle and package without Developer ID, notarization or the
#                 Sparkle public key (ad-hoc signed so it still launches on the Mini)
#
# Run it from any checkout: off the Mini it copies the checkout to the Mini and runs there over ssh.
# Output: /Volumes/DevVault/Dev/betterdock-release/out/<version>/{BetterDock.app,BetterDock-<version>.dmg}
set -euo pipefail
source "${0:A:h}/lib.sh"

version="${1:-}"; shift || true
unsigned=false
for arg in "$@"; do
  case "$arg" in
    --unsigned) unsigned=true ;;
    *) die "unknown option: $arg" ;;
  esac
done
valid_version "$version" || die "usage: release/build-release.sh <X.Y.Z> [--unsigned]"

if ! on_mini; then
  step "Copying the checkout to the Mac mini ($MINI_HOST)"
  src=$(sync_to_mini)
  run_on_mini "zsh '$src/release/build-release.sh' $version $*"; exit $?
fi

export TMPDIR="$MINI_ROOT/tmp"
mkdir -p "$TMPDIR"
out="$MINI_ROOT/out/$version"
build="$MINI_ROOT/build/$version"
rm -rf "$out" "$build"
mkdir -p "$out" "$build"

step "Sparkle $SPARKLE_VERSION"
sparkle_dir=$("$REPO_ROOT/release/fetch-sparkle.sh")
print "$sparkle_dir"

public_key=""
[[ -f "$PUBLIC_KEY_FILE" ]] && public_key=$(tr -d ' \n' < "$PUBLIC_KEY_FILE")
if [[ -z "$public_key" ]]; then
  $unsigned || die "packaging/sparkle-public-key.txt is missing. Run release/sparkle-keys.sh once and commit the key it writes."
  print "warning: no Sparkle public key yet; this dry-run build cannot install updates"
fi

step "Compiling"
sources=("$REPO_ROOT"/Sources/Shared/*.swift "$REPO_ROOT"/Sources/DockApp/*.swift)
flags=(-O -F "$sparkle_dir" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
slices=()
for arch in arm64 x86_64; do
  print "$arch"
  swiftc "${flags[@]}" -target "$arch-apple-macos$MIN_MACOS" -module-cache-path "$build/module-cache" \
    -o "$build/$APP_NAME-$arch" "${sources[@]}"
  slices+=("$build/$APP_NAME-$arch")
done
lipo -create "${slices[@]}" -output "$build/$APP_NAME"
lipo -info "$build/$APP_NAME"

step "Assembling $APP_NAME.app"
app="$build/$APP_NAME.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
cp "$build/$APP_NAME" "$app/Contents/MacOS/$APP_NAME"
ditto "$sparkle_dir/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
ditto "$REPO_ROOT/examples" "$app/Contents/Resources/examples"
"$REPO_ROOT/packaging/make-icon.sh" "$app/Contents/Resources/AppIcon.icns" >/dev/null

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © $(date +%Y) Bilal Bjo. MIT License.</string>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your next event in the Calendar widget.</string>
  <key>NSAppleEventsUsageDescription</key><string>Shows and controls what Spotify or Music is playing in the Now Playing widget.</string>
  <key>SUFeedURL</key><string>$FEED_URL</string>
  <key>SUPublicEDKey</key><string>$public_key</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null

if $unsigned; then
  step "Ad-hoc signing (dry run, no Developer ID)"
  codesign --force --sign - "$app"
  codesign --verify --strict "$app"
  ditto "$app" "$out/$APP_NAME.app"
  make_dmg "$out/$APP_NAME.app" "$out/$APP_NAME-$version-unsigned.dmg"
  step "Dry run done"
  print "$out/$APP_NAME.app"
  print "$out/$APP_NAME-$version-unsigned.dmg"
  exit 0
fi

# Signing and notarization need the login keychain, which only the GUI session can use, and the GUI
# session cannot touch /Volumes/DevVault, so the job runs in a private /tmp directory.
step "Signing and notarizing in the Mini's GUI session"
job=$(mktemp -d /tmp/betterdock-release.XXXXXX)
trap 'rm -rf "$job"' EXIT
ditto "$app" "$job/$APP_NAME.app"
cp "$REPO_ROOT/packaging/$APP_NAME.entitlements" "$REPO_ROOT/release/lib.sh" "$job/"
"$REPO_ROOT/release/mini-gui-run.sh" "$job" "$REPO_ROOT/release/sign-and-notarize.sh" "$job" "$version" \
  || { cp "$job/job.log" "$out/sign-and-notarize.log" 2>/dev/null || true; die "signing/notarization failed; log: $out/sign-and-notarize.log"; }
cp "$job/job.log" "$out/sign-and-notarize.log"
ditto "$job/$APP_NAME.app" "$out/$APP_NAME.app"
cp "$job/$APP_NAME-$version.dmg" "$out/"

step "Release $version ready"
print "$out/$APP_NAME-$version.dmg"
shasum -a 256 "$out/$APP_NAME-$version.dmg"
print "Next: release/make-appcast.sh $version"
