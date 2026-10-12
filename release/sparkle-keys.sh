#!/bin/zsh
# Creates (once) the EdDSA key pair that signs BetterDock updates, and records the public key.
#
#   release/sparkle-keys.sh
#
# Runs Sparkle's generate_keys in the Mac mini's GUI session. The private key is stored only in the
# Mini's login keychain (item "Private key for signing Sparkle updates", account "betterdock") and is
# never printed or copied. An existing key is reused, never replaced.
# The public key is written to packaging/sparkle-public-key.txt in THIS checkout; commit that file.
# Back the private key up once from the Mini's screen: generate_keys --account betterdock -x <file>
# into your password manager. Losing it means existing installs can no longer verify updates.
set -euo pipefail
source "${0:A:h}/lib.sh"

if [[ "${1:-}" != --on-mini ]]; then
  if on_mini; then
    output=$(zsh "$0" --on-mini)
  else
    step "Copying the checkout to the Mac mini ($MINI_HOST)"
    src=$(sync_to_mini)
    output=$(run_on_mini "zsh '$src/release/sparkle-keys.sh' --on-mini") || { print -r -- "$output"; die "sparkle-keys failed on the Mini"; }
  fi
  print -r -- "$output" | grep -v '^BETTERDOCK_PUBLIC_KEY=' || true
  key=$(print -r -- "$output" | sed -n 's/^BETTERDOCK_PUBLIC_KEY=//p' | tail -1)
  [[ "$key" =~ '^[A-Za-z0-9+/=]{40,}$' ]] || die "could not read the public key from generate_keys"
  print -r -- "$key" > "$PUBLIC_KEY_FILE"
  step "Public key"
  print "$key"
  print "Written to packaging/sparkle-public-key.txt (embedded as SUPublicEDKey by build-release.sh). Commit it."
  exit 0
fi

# --on-mini: stage generate_keys in /tmp (the GUI session cannot read /Volumes/DevVault) and run it there.
export TMPDIR="$MINI_ROOT/tmp"; mkdir -p "$TMPDIR"
sparkle_dir=$("$REPO_ROOT/release/fetch-sparkle.sh")
job=$(mktemp -d /tmp/betterdock-keys.XXXXXX)
trap 'rm -rf "$job"' EXIT
cp "$sparkle_dir/bin/generate_keys" "$job/"
cat > "$job/keys.sh" <<JOB
set -euo pipefail
cd "$job"
if ! key=\$(./generate_keys --account $SPARKLE_KEY_ACCOUNT -p 2>/dev/null); then
  print "No BetterDock update key yet; generating one in the login keychain."
  ./generate_keys --account $SPARKLE_KEY_ACCOUNT >/dev/null
  key=\$(./generate_keys --account $SPARKLE_KEY_ACCOUNT -p)
else
  print "Reusing the existing BetterDock update key."
fi
print "BETTERDOCK_PUBLIC_KEY=\$key"
JOB
"$REPO_ROOT/release/mini-gui-run.sh" "$job" "$job/keys.sh" \
  || die "generate_keys failed in the GUI session (if a keychain prompt appeared on the Mini's screen, allow it and rerun)"
