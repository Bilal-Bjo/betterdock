#!/bin/zsh
# Publishes a built, notarized release to GitHub and renders the Homebrew cask.
#
#   release/publish.sh <version> [--tap]
#
# Run from the developer checkout (release notes come from git). The upload itself runs on the Mac
# mini, where the DMG and appcast were produced:
#   1. checks the commit is on GitHub, the DMG is stapled and the appcast lists this version
#   2. gh release create v<version> --target <HEAD> --latest, uploading BetterDock-<version>.dmg and appcast.xml
#   3. verifies the public feed and download URLs answer
#   4. writes the cask with the DMG's sha256 to out/<version>/betterdock.rb (and prints it)
#   --tap  also commits that cask to Bilal-Bjo/homebrew-tap as Casks/betterdock.rb (repo must exist)
set -euo pipefail
source "${0:A:h}/lib.sh"

version="${1:-}"; shift || true
valid_version "$version" || die "usage: release/publish.sh <X.Y.Z> [--tap]"
tap=false; on_mini_pass=false; sha=""
while (( $# )); do
  case "$1" in
    --tap) tap=true ;;
    --on-mini) on_mini_pass=true; sha="${2:?}"; shift ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done
tag="v$version"
out="$MINI_ROOT/out/$version"
dmg="$out/$APP_NAME-$version.dmg"
TAP_REPO="Bilal-Bjo/homebrew-tap"

if ! $on_mini_pass; then
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "run publish.sh from a git checkout"
  [[ -z $(git -C "$REPO_ROOT" status --porcelain --untracked-files=no) ]] || die "the checkout has uncommitted changes"
  sha=$(git -C "$REPO_ROOT" rev-parse HEAD)
  gh api "repos/$GITHUB_REPO/commits/$sha" --silent 2>/dev/null \
    || die "commit ${sha:0:12} is not on GitHub yet. Push it first (the release tag is created on it)."
  notes=$(release_notes "$version")
  args=("$version" --on-mini "$sha"); $tap && args+=(--tap)
  if on_mini; then
    print -r -- "$notes" > "$out/release-notes.md"
    exec zsh "$0" "${args[@]}"
  fi
  step "Copying the checkout to the Mac mini ($MINI_HOST)"
  src=$(sync_to_mini)
  print -r -- "$notes" | ssh "$MINI_HOST" "mkdir -p '$out' && cat > '$out/release-notes.md'"
  remote_args=${(j: :)${(q)args[@]}}
  run_on_mini "zsh '$src/release/publish.sh' $remote_args"; exit $?
fi

# On the Mini.
export TMPDIR="$MINI_ROOT/tmp"; mkdir -p "$TMPDIR"
step "Preflight"
[[ -f "$dmg" ]] || die "$dmg not found. Run release/build-release.sh $version first."
[[ -f "$out/appcast.xml" ]] || die "$out/appcast.xml not found. Run release/make-appcast.sh $version first."
xcrun stapler validate -q "$dmg" || die "${dmg:t} is not notarized and stapled"
spctl -a -t open --context context:primary-signature "$dmg" 2>/dev/null || die "Gatekeeper rejects ${dmg:t}"
grep -q "releases/download/$tag/${dmg:t}" "$out/appcast.xml" || die "appcast.xml does not list ${dmg:t}"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated on the Mini (gh auth login)"
if gh release view "$tag" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
  die "release $tag already exists on GitHub. Bump the version instead of replacing a published build."
fi
checksum=$(shasum -a 256 "$dmg" | awk '{print $1}')
print "DMG sha256: $checksum"

step "Creating GitHub release $tag"
gh release create "$tag" --repo "$GITHUB_REPO" --target "$sha" --title "$APP_NAME $version" \
  --notes-file "$out/release-notes.md" --latest "$dmg" "$out/appcast.xml"

step "Checking public URLs"
asset_url="https://github.com/$GITHUB_REPO/releases/download/$tag/${dmg:t}"
for url in "$FEED_URL" "$asset_url"; do
  for attempt in 1 2 3 4 5; do
    curl -fsIL -o /dev/null "$url" && { print "ok  $url"; break; }
    (( attempt < 5 )) || die "not reachable: $url"
    sleep 5
  done
done
curl -fsSL "$FEED_URL" | grep -q "releases/download/$tag/" || die "the latest feed does not list $tag yet"

step "Homebrew cask"
sed -e "s/__VERSION__/$version/" -e "s/__SHA256__/$checksum/" "$REPO_ROOT/packaging/homebrew/betterdock.rb" \
  | grep -v '^# ' > "$out/betterdock.rb"
cat "$out/betterdock.rb"

if $tap; then
  step "Updating $TAP_REPO"
  gh repo view "$TAP_REPO" >/dev/null 2>&1 || die "$TAP_REPO does not exist yet (see RELEASING.md)"
  clone=$(mktemp -d "$TMPDIR/tap.XXXXXX")
  gh repo clone "$TAP_REPO" "$clone" -- --depth 1 >/dev/null 2>&1
  mkdir -p "$clone/Casks"
  cp "$out/betterdock.rb" "$clone/Casks/betterdock.rb"
  git -C "$clone" add Casks/betterdock.rb
  git -C "$clone" commit -qm "betterdock $version"
  git -C "$clone" push -q
  rm -rf "$clone"
  print "brew install --cask bilal-bjo/tap/betterdock"
fi

step "Published $tag"
print "https://github.com/$GITHUB_REPO/releases/tag/$tag"
