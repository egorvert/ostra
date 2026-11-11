#!/bin/zsh
# Runs Ostra with a scripted key sequence and captures its window at set times.
# Scripted runs stay in the background and never save settings.
#
# Usage: Scripts/snapshot.sh <out-dir> "<steps>" name:seconds [name:seconds ...]
#
# Steps are separated by spaces. See DebugScript in Sources/Ostra/App/OstraApp.swift:
#   wait:1.5  key:tab  key:shift+d  key:cmd+,  type:hello_world  send
#   project:/path  model:codex/gpt-5.6-luna  tool:files  frost:0  appearance:dark  quit
#
# Set OSTRA_LIVE=1 to use the real engine; the default is the simulated one.
#
# Example:
#   Scripts/snapshot.sh /tmp/shots "wait:2.6 key:tab key:space wait:1.5" chat:4.5
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$1"; STEPS="$2"; shift 2
mkdir -p "$OUT"
swift build --product Ostra >/dev/null
BIN="$(swift build --show-bin-path)/Ostra"
LISTER="$OUT/.winlist"
[ -x "$LISTER" ] || swiftc -O -o "$LISTER" Scripts/winlist.swift

if [[ -z "${OSTRA_LIVE:-}" ]]; then
  export OSTRA_DEMO=1
  rm -f "$HOME/Library/Application Support/Ostra/ui-state-demo.json"
fi
OSTRA_SCRIPT="$STEPS" "$BIN" >"$OUT/app.log" 2>&1 &
PID=$!
START=$(date +%s.%N)
for spec in "$@"; do
  name=${spec%%:*}; at=${spec##*:}
  delay=$(( at - ($(date +%s.%N) - START) ))
  (( delay > 0 )) && sleep $delay
  WID=$("$LISTER" Ostra | head -1 | awk '{print $1}')
  if [ -n "$WID" ]; then
    screencapture -x -o -l"$WID" "$OUT/$name.png"
  else
    echo "No Ostra window on screen for '$name'."
  fi
done
kill -TERM $PID 2>/dev/null || true
wait $PID 2>/dev/null || true
