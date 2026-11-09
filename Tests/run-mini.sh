#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
remote="/Volumes/DevVault/Dev/betterdock-verification"
source "$root/release/lib.sh"
ssh mini "mkdir -p '$remote/src' '$remote/tmp' '$remote/build'"
rsync -a --delete --exclude .git --exclude config --exclude build --exclude .claude "$root/" "mini:$remote/src/"
run_on_mini "zsh '$remote/src/Tests/verify-on-mini.sh' $*"
