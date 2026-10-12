#!/bin/zsh
# Runs one script inside the Mac mini's logged-in GUI session, then removes every trace of the job.
#
#   release/mini-gui-run.sh <job-dir> <script> [args...]
#
# Why: code signing identities, the notarytool keychain profile and Sparkle's EdDSA key live in the
# login keychain, which a plain ssh session cannot see (it falsely reports zero identities). A scoped,
# one-shot LaunchAgent in gui/<uid> runs with the unlocked keychain.
#
# Constraints of the GUI-session agent: it cannot read or write /Volumes/DevVault (removable-volume
# privacy), so <job-dir> must be under /tmp and hold everything the script touches. The log is written
# there and streamed back here; the caller copies results out afterwards.
#
# Must run on the Mini itself (build-release.sh and friends call it over ssh).
set -euo pipefail

(( $# >= 2 )) || { print -u2 "usage: $0 <job-dir under /tmp> <script> [args...]"; exit 2; }
job="$1"; script="$2"; shift 2
[[ "$job" == /tmp/* || "$job" == /private/tmp/* ]] || { print -u2 "error: job dir must be under /tmp (got $job)"; exit 2; }
[[ -f "$script" ]] || { print -u2 "error: no such script: $script"; exit 2; }
[[ -d /Volumes/DevVault/Dev ]] || { print -u2 "error: mini-gui-run.sh must run on the Mac mini"; exit 2; }

uid=$(id -u)
launchctl print "gui/$uid" >/dev/null 2>&1 \
  || { print -u2 "error: user $(id -un) has no logged-in GUI session on this Mac. Log in at the Mini's screen (or Screen Sharing) and retry."; exit 3; }

mkdir -p "$job"
label="com.betterdock.release.$(date +%s).$$"
plist="$job/$label.plist"
log="$job/job.log"
exit_file="$job/job.exit"
rm -f "$log" "$exit_file"
cp "$script" "$job/job.sh"

job_args=${(j: :)${(q)@}}
# The wrapper records the exit status even when the script fails, so we know when it finished.
cat > "$job/wrapper.sh" <<WRAP
#!/bin/zsh
cd "$job"
export TMPDIR="$job/tmp"; mkdir -p "\$TMPDIR"
/bin/zsh "$job/job.sh" $job_args > "$log" 2>&1
print \$? > "$exit_file.partial" && mv "$exit_file.partial" "$exit_file"
WRAP

cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$job/wrapper.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>LaunchOnlyOnce</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$job/launchd.log</string>
  <key>StandardErrorPath</key><string>$job/launchd.log</string>
</dict></plist>
PLIST

cleanup() {
  launchctl bootout "gui/$uid/$label" >/dev/null 2>&1 || true
  rm -f "$plist" "$job/wrapper.sh" "$job/job.sh"
}
trap cleanup EXIT INT TERM

launchctl bootstrap "gui/$uid" "$plist"

# Stream the log while waiting. Notarization can take a while; give up after GUI_JOB_TIMEOUT_MIN (90).
timeout=$(( ${GUI_JOB_TIMEOUT_MIN:-90} * 60 )); waited=0; shown=0
while [[ ! -f "$exit_file" ]]; do
  sleep 2; (( waited += 2 ))
  if [[ -f "$log" ]]; then
    lines=$(wc -l < "$log" | tr -d ' ')
    (( lines > shown )) && { sed -n "$((shown + 1)),${lines}p" "$log"; shown=$lines; }
  fi
  (( waited < timeout )) || { print -u2 "error: GUI job timed out after $((timeout / 60)) minutes; log: $log"; exit 4; }
done
[[ -f "$log" ]] && sed -n "$((shown + 1)),\$p" "$log"
code=$(<"$exit_file")
exit "$code"
