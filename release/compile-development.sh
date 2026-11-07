#!/bin/zsh
# Native compilation always runs on the Mini; the coordinator only receives the executable.
set -euo pipefail
source "${0:A:h}/lib.sh"
destination="${1:?output executable required}"
base="/Volumes/DevVault/Dev/betterdock-verification"
if [[ -n "${BETTERDOCK_BUILD_HOST:-}" ]] && ! on_mini; then
  MINI_HOST="$BETTERDOCK_BUILD_HOST"
  ssh "$MINI_HOST" "mkdir -p '$base/src' '$base/build' '$base/tmp'"
  rsync -a --delete --exclude .git --exclude config --exclude build --exclude .claude --exclude packaging/vendor \
    "$REPO_ROOT/" "$MINI_HOST:$base/src/"
  run_on_mini "zsh '$base/src/release/compile-development.sh' '$base/build/BetterDock-development'"
  rsync -a "$MINI_HOST:$base/build/BetterDock-development" "$destination"
  exit 0
fi
if on_mini; then
  export TMPDIR="$base/tmp"
  mkdir -p "$TMPDIR" "$base/build/modules"
else
  base="$REPO_ROOT/build/native"
  mkdir -p "$base/build/modules"
fi
xcrun swiftc -O -target arm64-apple-macos14.0 -module-cache-path "$base/build/modules" \
  -o "$destination" "$REPO_ROOT"/Sources/Shared/*.swift "$REPO_ROOT"/Sources/DockApp/*.swift
