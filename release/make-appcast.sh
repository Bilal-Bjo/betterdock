#!/bin/zsh
# Generates the signed Sparkle appcast for a built release.
#
#   release/make-appcast.sh <version> [--unsigned] [--base <appcast.xml>]
#
#   --unsigned        use the dry-run DMG from `build-release.sh <version> --unsigned` (testing only)
#   --base <file>     start from this appcast (on the Mini) instead of the published one
#
# Starts from the currently published feed ($FEED_URL, if any), adds the new DMG with Sparkle's
# generate_appcast (EdDSA-signed with the key in the Mini's login keychain, so it runs in the GUI
# session), and points the new enclosure at the versioned GitHub release asset:
#   https://github.com/Bilal-Bjo/betterdock/releases/download/v<version>/BetterDock-<version>.dmg
# Release notes (commit subjects since the last tag) are embedded.
# Output: /Volumes/DevVault/Dev/betterdock-release/out/<version>/appcast.xml
set -euo pipefail
source "${0:A:h}/lib.sh"

version="${1:-}"; shift || true
valid_version "$version" || die "usage: release/make-appcast.sh <X.Y.Z> [--unsigned] [--base <appcast.xml>]"
unsigned=false; base=""; on_mini_pass=false
while (( $# )); do
  case "$1" in
    --unsigned) unsigned=true ;;
    --base) base="${2:?--base needs a file}"; shift ;;
    --on-mini) on_mini_pass=true ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

dmg_name="$APP_NAME-$version.dmg"
$unsigned && dmg_name="$APP_NAME-$version-unsigned.dmg"
out="$MINI_ROOT/out/$version"

if ! $on_mini_pass; then
  # Release notes come from git, which only the developer checkout has.
  notes=$(release_notes "$version")
  args=("$version"); $unsigned && args+=(--unsigned); [[ -n "$base" ]] && args+=(--base "$base")
  if on_mini; then
    mkdir -p "$out"; print -r -- "$notes" > "$out/notes.md"
    exec zsh "$0" "${args[@]}" --on-mini
  fi
  step "Copying the checkout to the Mac mini ($MINI_HOST)"
  src=$(sync_to_mini)
  print -r -- "$notes" | ssh "$MINI_HOST" "mkdir -p '$out' && cat > '$out/notes.md'"
  remote_args=${(j: :)${(q)args[@]}}
  run_on_mini "zsh '$src/release/make-appcast.sh' $remote_args --on-mini"; exit $?
fi

# On the Mini.
export TMPDIR="$MINI_ROOT/tmp"; mkdir -p "$TMPDIR"
[[ -f "$out/$dmg_name" ]] || die "$out/$dmg_name not found. Run release/build-release.sh $version first."
if ! $unsigned; then
  xcrun stapler validate -q "$out/$dmg_name" || die "$dmg_name is not notarized and stapled; refusing to publish it in the feed"
fi
sparkle_dir=$("$REPO_ROOT/release/fetch-sparkle.sh")

job=$(mktemp -d /tmp/betterdock-appcast.XXXXXX)
trap 'rm -rf "$job"' EXIT
mkdir -p "$job/archives"
ditto "$sparkle_dir/bin" "$job/bin"
cp "$out/$dmg_name" "$job/archives/"
[[ -f "$out/notes.md" ]] && cp "$out/notes.md" "$job/archives/${dmg_name:r}.md"

step "Current feed"
if [[ -n "$base" ]]; then
  cp "$base" "$job/archives/appcast.xml"; print "Using $base"
elif curl -fsSL --retry 2 -o "$job/archives/appcast.xml" "$FEED_URL"; then
  print "Extending $FEED_URL ($(grep -c '<item>' "$job/archives/appcast.xml") existing items)"
else
  rm -f "$job/archives/appcast.xml"; print "No published feed yet; starting a new one"
fi

# generate_appcast reading the keychain item itself triggers a GUI "allow access" prompt, because only
# generate_keys (which created the item) is on its access list. So generate_keys exports the key to a
# private 0600 file inside this job, generate_appcast reads it, and the file is deleted right after.
cat > "$job/appcast.sh" <<JOB
set -euo pipefail
cd "$job"
umask 077
mkdir -m 700 "$job/key"
trap 'rm -rf "$job/key"' EXIT
./bin/generate_keys --account $SPARKLE_KEY_ACCOUNT -x "$job/key/ed25519" >/dev/null
./bin/generate_appcast --ed-key-file "$job/key/ed25519" \\
  --download-url-prefix "https://github.com/$GITHUB_REPO/releases/download/v$version/" \\
  --link "https://github.com/$GITHUB_REPO" --embed-release-notes --maximum-deltas 0 \\
  "$job/archives"
JOB
step "Signing the feed in the Mini's GUI session"
GUI_JOB_TIMEOUT_MIN=15 "$REPO_ROOT/release/mini-gui-run.sh" "$job" "$job/appcast.sh" \
  || die "generate_appcast failed (if the Mini showed a keychain prompt for generate_keys, choose Always Allow and rerun)"
[[ ! -e "$job/key" ]] || die "exported key was not cleaned up"

grep -q "sparkle:edSignature" "$job/archives/appcast.xml" || die "appcast has no EdDSA signature"
grep -q "releases/download/v$version/$dmg_name" "$job/archives/appcast.xml" || die "appcast does not reference $dmg_name"
cp "$job/archives/appcast.xml" "$out/appcast.xml"
step "Appcast ready"
print "$out/appcast.xml"
$unsigned || print "Next: release/publish.sh $version"
