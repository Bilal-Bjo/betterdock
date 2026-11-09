#!/bin/zsh
set -euo pipefail
job="$1"
export BETTERDOCK_CONFIG_DIR="$job/config"
mkdir -p "$BETTERDOCK_CONFIG_DIR/folders"
cp "$job/examples/dock.json" "$BETTERDOCK_CONFIG_DIR/dock.json"
cp "$job/examples/folders/"*.json "$BETTERDOCK_CONFIG_DIR/folders/"
"$job/BetterDock.app/Contents/MacOS/BetterDock" --self-test
"$job/BetterDock.app/Contents/MacOS/BetterDock" --preview --e2e-test
