#!/bin/zsh
# Builds AppIcon.icns from packaging/logo.svg on the build machine.
#
#   packaging/make-icon.sh <out.icns>
#
# The logo is a full-bleed rounded tile, so it is placed on Apple's macOS icon grid: an 824 px body
# centred on a transparent 1024 px canvas. sips renders the SVG with real transparency (qlmanage
# thumbnails paint a white background, so they are not used for the master).
set -euo pipefail

out="${1:?usage: $0 <out.icns>}"
here="${0:A:h}"
work=$(mktemp -d "${TMPDIR:-/tmp}/appicon.XXXXXX")
trap 'rm -rf "$work"' EXIT

# Strip the outer <svg> element and nest the artwork in the 824/1024 body box.
inner=$(sed -e 's/<svg[^>]*>//' -e 's#</svg>##' "$here/logo.svg")
print -r -- "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1024\" height=\"1024\" viewBox=\"0 0 1024 1024\"><svg x=\"100\" y=\"100\" width=\"824\" height=\"824\" viewBox=\"0 0 100 100\">$inner</svg></svg>" > "$work/icon.svg"

sips -s format png "$work/icon.svg" --out "$work/master.png" >/dev/null
[[ $(sips -g pixelWidth "$work/master.png" | awk '/pixelWidth/ {print $2}') == 1024 ]] || { print -u2 "error: icon master is not 1024 px"; exit 1; }
[[ $(sips -g hasAlpha "$work/master.png" | awk '/hasAlpha/ {print $2}') == yes ]] || { print -u2 "error: icon master has no alpha"; exit 1; }

set_dir="$work/AppIcon.iconset"
mkdir -p "$set_dir"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/master.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
  double=$(( size * 2 ))
  sips -z $double $double "$work/master.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o "$out"
print "$out"
