#!/bin/bash
# Pulse installer: builds the app on this Mac, installs it, and walks through optional setup.
# Run from the Pulse folder:  ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
ask()  { local reply; read -r -p "$1 " reply </dev/tty; [[ -z "$reply" && "$2" == y ]] || [[ "$reply" =~ ^[Yy] ]]; }

say "Pulse · menu bar CPU, memory and AI usage monitor"

# 1. Requirements
[[ "$(uname -m)" == arm64 ]] || { echo "Pulse needs an Apple Silicon Mac."; exit 1; }
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || { echo "Pulse needs macOS 14 or later."; exit 1; }
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Pulse needs Apple's free Command Line Tools to build (and to read Claude/Codex usage)."
  xcode-select --install || true
  echo "Finish the install window that just opened, then run this installer again."
  exit 1
fi

# 2. Build and install (a locally built app isn't blocked by Gatekeeper the way a browser download is)
say "Building Pulse…"
log=$(mktemp); ./scripts/build.sh >"$log" 2>&1 || { cat "$log"; echo "Build failed."; exit 1; }
osascript -e 'tell application id "local.koz46.pulse" to quit' >/dev/null 2>&1 || true
mkdir -p ~/Applications
rm -rf ~/Applications/Pulse.app
cp -R build.noindex/Pulse.app ~/Applications/Pulse.app
echo "Installed to ~/Applications/Pulse.app"

# 3. Claude: exact limits need a Claude Code login; without one Pulse shows tokens used instead.
say "Claude usage"
if command -v claude >/dev/null 2>&1; then
  if ask "Connect Claude for exact 5-hour and weekly limits? [Y/n]" y; then
    claude auth login || echo "Sign-in didn't finish. You can connect later from Pulse (Connect next to Claude)."
  fi
else
  echo "Claude Code isn't installed, so Pulse will show Claude tokens used (if any) instead of exact limits."
  echo "To get exact limits later: install Claude Code (https://claude.com/claude-code), then click Connect in Pulse."
fi
defaults write local.koz46.pulse claudeOnboardingDone -bool true  # Already handled here; skip the in-app card.

# 4. Optional: Claude Code status line + agent advisory (edits ~/.claude/settings.json and CLAUDE.md files)
if command -v claude >/dev/null 2>&1 && ask "Also add Pulse to Claude Code's status line and agent instructions? Edits your Claude settings (backed up). [y/N]" n; then
  /usr/bin/python3 scripts/install-integrations.py
fi

# 5. Launch
open ~/Applications/Pulse.app
say "Done. Pulse is in your menu bar. Hover it for usage; click it for details."
echo "Tip: turn on Launch at login from Pulse's ••• menu."
