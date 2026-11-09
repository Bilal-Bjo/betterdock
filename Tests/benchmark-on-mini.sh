#!/bin/zsh
# Compare cursor sweeps on the Mini's logged-in GUI session, with fixed synthetic app tiles.
set -euo pipefail
root="${0:A:h:h}"
base=/Volumes/DevVault/Dev/betterdock-verification
binary="${1:-$base/build/BetterDock}"
budget="${2:-8.3}"
[[ -d /Volumes/DevVault/Dev && -x "$binary" ]] || { echo 'Build on the Mini first.' >&2; exit 1; }
mkdir -p "$base/perf" "$base/tmp"
job=$(mktemp -d /tmp/betterdock-perf.XXXXXX)
trap 'rm -rf "$job"' EXIT
mkdir -p "$job/BetterDock.app/Contents/MacOS" "$job/config/folders"
cp "$binary" "$job/BetterDock.app/Contents/MacOS/BetterDock"
python3 - "$job/config/dock.json" <<'PY'
import json,sys
config={'iconSize':44,'magnifiedSize':71,'autohide':False,'onboarded':True,'badges':False,
        'items':[{'app':f'/Applications/Benchmark{i}.app'} for i in range(24)]+[{'widget':'storage','size':'medium'}]}
with open(sys.argv[1],'w') as f: json.dump(config,f)
PY
cat > "$job/bench.sh" <<'JOB'
#!/bin/zsh
export BETTERDOCK_CONFIG_DIR="$1/config"
"$1/BetterDock.app/Contents/MacOS/BetterDock" --bench
JOB
"$root/release/mini-gui-run.sh" "$job" "$job/bench.sh" "$job"
cp "$job/job.log" "$base/perf/latest.log"
python3 - "$base/perf/latest.log" "$budget" <<'PY'
import re,sys
with open(sys.argv[1]) as f: text=f.read()
match=re.search(r'frame ms: median ([0-9.]+), p95 ([0-9.]+)',text)
if not match: raise SystemExit('No frame measurements produced')
p95=float(match[2]); budget=float(sys.argv[2])
print(f'Frame-budget check: p95={p95:.2f} ms, budget={budget:.2f} ms')
if p95>budget: raise SystemExit('FAIL: cursor-sweep frame budget exceeded')
print('PASS: cursor-sweep frame budget')
PY
