#!/bin/zsh
# Sign in the Mini's GUI keychain session, then return the signed development app.
set -euo pipefail
source "${0:A:h}/lib.sh"
app="${1:?app bundle required}"
if [[ -z "${BETTERDOCK_BUILD_HOST:-}" ]]; then
  identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
  codesign --force --sign "${identity:--}" "$app"
  codesign --verify --strict "$app"
  exit 0
fi
MINI_HOST="$BETTERDOCK_BUILD_HOST"
job=$(ssh "$MINI_HOST" 'mktemp -d /tmp/betterdock-development.XXXXXX' | tail -n 1)
[[ "$job" == /tmp/betterdock-development.* ]] || die 'Could not stage the GUI signing job.'
trap 'ssh "$MINI_HOST" "rm -rf '\''$job'\''" >/dev/null 2>&1 || true' EXIT
rsync -a "$app/" "$MINI_HOST:$job/BetterDock.app/"
base="/Volumes/DevVault/Dev/betterdock-verification/src"
run_on_mini "zsh '$base/release/mini-gui-run.sh' '$job' '$base/release/sign-development-job.sh' '$job'"
rsync -a --delete "$MINI_HOST:$job/BetterDock.app/" "$app/"
