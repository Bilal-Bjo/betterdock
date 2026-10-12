# Shared settings for the release scripts. Sourced, not run.
# Every native step (build, signing, notarization, appcast signing, uploads) runs on the Mac mini.

APP_NAME="BetterDock"
BUNDLE_ID="com.betterdock.app"
MIN_MACOS="14.0"
GITHUB_REPO="Bilal-Bjo/betterdock"
FEED_URL="https://github.com/$GITHUB_REPO/releases/latest/download/appcast.xml"

# Sparkle 2, pinned. SHA-256 of Sparkle-2.10.0.tar.xz from
# https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0 (matches GitHub's published asset digest).
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

# Keychain names on the Mini.
NOTARY_PROFILE="betterdock-notary"   # xcrun notarytool store-credentials betterdock-notary ...
SPARKLE_KEY_ACCOUNT="betterdock"     # generate_keys/generate_appcast --account (EdDSA key in the login keychain)

# Mac mini (Tailscale ssh alias). Heavy outputs and TMPDIR live on the external SSD.
MINI_HOST="${MINI_HOST:-mini}"
MINI_ROOT="/Volumes/DevVault/Dev/betterdock-release"

REPO_ROOT="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
VENDOR_DIR="$REPO_ROOT/packaging/vendor"
SPARKLE_DIR="$VENDOR_DIR/Sparkle-$SPARKLE_VERSION"
PUBLIC_KEY_FILE="$REPO_ROOT/packaging/sparkle-public-key.txt"

die() { print -u2 "error: $*"; exit 1; }
step() { print "\n==> $*"; }

on_mini() { [[ -d /Volumes/DevVault/Dev ]]; }

valid_version() { [[ "$1" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; }

# Copies this checkout to the Mini (keeping its Sparkle download cache) and prints the remote path.
sync_to_mini() {
  local dest="$MINI_ROOT/src"
  ssh "$MINI_HOST" "mkdir -p '$dest'" || die "cannot reach the Mac mini over ssh ($MINI_HOST)"
  rsync -a --delete \
    --exclude '/.git' --exclude '/build/' --exclude '/config/' --exclude '.DS_Store' --exclude '/packaging/vendor/' \
    "$REPO_ROOT/" "$MINI_HOST:$dest/" >&2 || die "rsync to the Mac mini failed"
  print "$dest"
}

# Runs a command on the Mini and returns its real exit status. The ssh transport on this setup reports
# 0 even when the remote command fails, so the status travels back as a sentinel line instead.
run_on_mini() {
  local code=255 line
  ssh "$MINI_HOST" "$1; echo BETTERDOCK_EXIT=\$?" | while IFS= read -r line; do
    if [[ "$line" == BETTERDOCK_EXIT=* ]]; then code=${line#BETTERDOCK_EXIT=}; else print -r -- "$line"; fi
  done
  return $code
}

# Developer ID identity, discovered at runtime. Only meaningful inside the Mini's GUI session.
developer_id_identity() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application: / {print $2; exit}'
}

# Markdown release notes: commit subjects since the previous v* tag. Needs a git checkout.
release_notes() {
  local version="$1" prev range
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { print "BetterDock $version"; return; }
  prev=$(git -C "$REPO_ROOT" describe --tags --abbrev=0 --match 'v[0-9]*' HEAD 2>/dev/null || true)
  range=${prev:+$prev..}HEAD
  print "## BetterDock $version\n"
  git -C "$REPO_ROOT" log --no-merges --format='- %s' "$range"
}

# Builds a compressed DMG holding the app and an /Applications symlink (no background or window layout).
make_dmg() {
  local app="$1" dmg="$2" stage
  stage=$(mktemp -d "${TMPDIR:-/tmp}/dmg.XXXXXX")
  ditto "$app" "$stage/${app:t}"
  ln -s /Applications "$stage/Applications"
  rm -f "$dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$stage" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$dmg"
  rm -rf "$stage"
}
