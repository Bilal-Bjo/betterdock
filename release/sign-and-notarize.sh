#!/bin/zsh
# Signs, packages, notarizes and staples BetterDock. Runs INSIDE the Mac mini's GUI session
# (started by build-release.sh through mini-gui-run.sh), where the keychain is unlocked.
#
#   sign-and-notarize.sh <job-dir> <version>
#
# <job-dir> (under /tmp) holds: BetterDock.app, BetterDock.entitlements, lib.sh.
# Produces: <job-dir>/BetterDock.app (signed, notarized, stapled) and <job-dir>/BetterDock-<version>.dmg.
set -euo pipefail
job="$1"; version="$2"
source "$job/lib.sh"
cd "$job"

app="$job/$APP_NAME.app"
entitlements="$job/$APP_NAME.entitlements"
dmg="$job/$APP_NAME-$version.dmg"
sparkle="$app/Contents/Frameworks/Sparkle.framework"
[[ -d "$app" && -f "$entitlements" ]] || die "job dir is missing the app or entitlements"

step "Checking signing prerequisites"
identity=$(developer_id_identity)
[[ -n "$identity" ]] || die "no 'Developer ID Application' identity in the Mini's login keychain.
  Create it at developer.apple.com (Certificates > Developer ID Application), install the .cer with its
  private key on the Mini (double-click in the GUI session), then confirm with:
    security find-identity -v -p codesigning"
print "Identity: $identity"

xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || die "notarytool keychain profile '$NOTARY_PROFILE' is missing or invalid. On the Mini (GUI session), run:
    xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <apple-id> --team-id <TEAMID>
  and enter an app-specific password from appleid.apple.com."
print "Notary profile: $NOTARY_PROFILE"

sign() { codesign --force --timestamp --options runtime --sign "$identity" "$@"; }

step "Signing (inside out: Sparkle helpers, framework, app)"
# Order from Sparkle's documentation for Developer ID builds outside Xcode.
sign "$sparkle/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$sparkle/Versions/B/XPCServices/Downloader.xpc"
sign "$sparkle/Versions/B/Autoupdate"
sign "$sparkle/Versions/B/Updater.app"
sign "$sparkle"
sign --entitlements "$entitlements" "$app"
codesign --verify --deep --strict --verbose=2 "$app"

notarize() {
  local file="$1" result id
  print "Submitting ${file:t} to Apple notary service (waits for the result)"
  # A rejected submission also exits non-zero; read the status either way and fetch Apple's log.
  result=$(xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist 2>"$job/notary.err") || true
  id=$(print -r -- "$result" | plutil -extract id raw -o - - 2>/dev/null || true)
  if [[ $(print -r -- "$result" | plutil -extract status raw -o - - 2>/dev/null) != Accepted ]]; then
    print -r -- "$result"; cat "$job/notary.err" >&2
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" || true
    die "notarization of ${file:t} was not accepted"
  fi
  print "Accepted (submission $id)"
}

step "Notarizing the app"
ditto -c -k --keepParent "$app" "$job/$APP_NAME.zip"
notarize "$job/$APP_NAME.zip"
rm -f "$job/$APP_NAME.zip"
xcrun stapler staple "$app"

step "Building and notarizing the DMG"
make_dmg "$app" "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
notarize "$dmg"
xcrun stapler staple "$dmg"

step "Verifying"
spctl -a -vvv -t exec "$app"
spctl -a -vvv -t install "$dmg"
spctl -a -vvv -t open --context context:primary-signature "$dmg"
xcrun stapler validate "$app"
xcrun stapler validate "$dmg"
print "\nSigned, notarized and stapled: ${dmg:t}"
