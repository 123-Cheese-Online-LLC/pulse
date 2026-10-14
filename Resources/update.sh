#!/bin/bash
# Pulse updater, run by the app: downloads one commit of Pulse from GitHub, builds it on this Mac,
# then quits Pulse, swaps the new app in and opens it. Pulse is left unchanged if any step fails.
# usage: update.sh <commit sha> <path to Pulse.app> <Pulse pid>
set -euo pipefail
sha=$1 app=$2 pid=$3
[[ $sha =~ ^[0-9a-f]{40}$ && $app == *.app && -d $app && $pid =~ ^[0-9]+$ ]] || exit 2
base="$HOME/Library/Application Support/Pulse"
work="$base/update"
mkdir -p "$base"
exec >"$base/update.log" 2>&1
echo "Updating Pulse to $sha ($(date))"
xcode-select -p >/dev/null 2>&1 || { xcode-select --install || true; exit 3; }

rm -rf "$work"; mkdir -p "$work"; cd "$work"
curl -fsSL --max-time 300 "https://codeload.github.com/123-Cheese-Online-LLC/pulse/tar.gz/$sha" | tar xz --strip-components 1
PULSE_COMMIT=$sha ./scripts/build.sh

# Built fine: quit Pulse (it's waiting on this script), swap, relaunch.
osascript -e 'tell application id "local.koz46.pulse" to quit' || kill "$pid" || true
for _ in $(seq 100); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$pid" 2>/dev/null && kill -9 "$pid"
rm -rf "$app.old"
mv "$app" "$app.old"
if cp -R build.noindex/Pulse.app "$app"; then rm -rf "$app.old"; else rm -rf "$app"; mv "$app.old" "$app"; fi
open "$app"
cd "$base"; rm -rf "$work"
echo "Done"
