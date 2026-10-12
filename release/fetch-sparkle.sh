#!/bin/zsh
# Downloads the pinned Sparkle 2 release into packaging/vendor/Sparkle-<version> and verifies its SHA-256.
# Idempotent: an already-verified copy is reused. Prints the Sparkle directory.
set -euo pipefail
source "${0:A:h}/lib.sh"

if [[ -f "$SPARKLE_DIR/.verified" && -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
  print "$SPARKLE_DIR"; exit 0
fi

mkdir -p "$VENDOR_DIR"
work=$(mktemp -d "${TMPDIR:-/tmp}/sparkle.XXXXXX")
trap 'rm -rf "$work"' EXIT

print -u2 "Downloading Sparkle $SPARKLE_VERSION"
curl -fsSL --retry 3 -o "$work/sparkle.tar.xz" "$SPARKLE_URL" || die "download failed: $SPARKLE_URL"
actual=$(shasum -a 256 "$work/sparkle.tar.xz" | awk '{print $1}')
[[ "$actual" == "$SPARKLE_SHA256" ]] \
  || die "Sparkle checksum mismatch. expected $SPARKLE_SHA256, got $actual. Refusing to use it."

mkdir -p "$work/x"
tar -xJf "$work/sparkle.tar.xz" -C "$work/x"
[[ -d "$work/x/Sparkle.framework/Versions/B/Modules" && -x "$work/x/bin/generate_appcast" ]] \
  || die "unexpected Sparkle archive layout"

rm -rf "$SPARKLE_DIR"
mkdir -p "$SPARKLE_DIR"
# ditto keeps the framework's symlinks and existing signatures intact.
ditto "$work/x/Sparkle.framework" "$SPARKLE_DIR/Sparkle.framework"
ditto "$work/x/bin" "$SPARKLE_DIR/bin"
cp "$work/x/LICENSE" "$SPARKLE_DIR/LICENSE"
print "$SPARKLE_SHA256" > "$SPARKLE_DIR/.verified"
print "$SPARKLE_DIR"
