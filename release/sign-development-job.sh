#!/bin/zsh
set -euo pipefail
job="$1"
app="$job/BetterDock.app"
identity=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')
fi
codesign --force --sign "${identity:--}" "$app"
codesign --verify --strict "$app"
print 'Development signature verified.'
