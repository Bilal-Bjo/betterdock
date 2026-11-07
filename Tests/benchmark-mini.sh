#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
source "$root/release/lib.sh"
"$root/Tests/run-mini.sh" --build-only
remote_args=${(j: :)${(q)@}}
run_on_mini "zsh '/Volumes/DevVault/Dev/betterdock-verification/src/Tests/benchmark-on-mini.sh' $remote_args"
