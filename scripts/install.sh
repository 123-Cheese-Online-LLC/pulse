#!/bin/bash
# Pulse installer: builds the app on this Mac, installs it, and walks through optional setup.
# Run from the Pulse folder:  ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

# Colors only in a real terminal, and never when NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  R=$'\033[31m' Y=$'\033[33m' B=$'\033[34m' G=$'\033[32m' D=$'\033[2m' BOLD=$'\033[1m' X=$'\033[0m'
else
  R='' Y='' B='' G='' D='' BOLD='' X=''
fi

step=0; steps=4
section() { step=$((step + 1)); printf '\n%s[%d/%d]%s %s\n' "$D" "$step" "$steps" "$X" "$1"; }
ok()   { printf '      %s✓%s %s\n' "$G" "$X" "$1"; }
note() { printf '      %s%s%s\n' "$D" "$1" "$X"; }
fail() { printf '      %s✗%s %s\n' "$R" "$X" "$1"; exit 1; }
ask()  { local reply; read -r -p "      $1 " reply </dev/tty; [[ -z "$reply" && "$2" == y ]] || [[ "$reply" =~ ^[Yy] ]]; }

# Runs a command in the background with a spinner and a timer; shows its log only if it fails.
# usage: spin "doing it…" "done" command args
spin() {
  local label=$1 done=$2; shift 2
  local log; log=$(mktemp)
  "$@" >"$log" 2>&1 &
  local pid=$! i=0 start=$SECONDS frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  if [[ -t 1 ]]; then
    while kill -0 "$pid" 2>/dev/null; do
      local t=$((SECONDS - start))
      printf '\r      %s%s%s %s %s%d:%02d%s ' "$Y" "${frames[i++ % 10]}" "$X" "$label" "$D" $((t / 60)) $((t % 60)) "$X"
      sleep 0.1
    done
    printf '\r\033[K'
  fi
  if wait "$pid"; then ok "$done ($((SECONDS - start))s)"; else cat "$log"; fail "${label%…} failed"; fi
}

cat <<BANNER

  ${R}.---.${X}   ${Y}.---.${X}   ${B}.---.${X}
 ${R}/  1  \\${X} ${Y}/  2  \\${X} ${B}/  3  \\${X}    ${BOLD}pulse${X}
 ${R}\\     /${X} ${Y}\\     /${X} ${B}\\     /${X}    ${D}cpu, memory & ai usage in your menu bar${X}
  ${R}'---'${X}   ${Y}'---'${X}   ${B}'---'${X}     ${D}by 123 Cheese Online${X}
BANNER

# 1. Requirements
section "checking your mac"
[[ "$(uname -m)" == arm64 ]] || fail "Pulse needs an Apple Silicon Mac."
ok "apple silicon"
[[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ]] || fail "Pulse needs macOS 14 or later."
ok "macOS $(sw_vers -productVersion)"
if ! xcode-select -p >/dev/null 2>&1; then
  note "Pulse needs Apple's free Command Line Tools to build (and to read Claude/Codex usage)."
  xcode-select --install || true
  fail "finish the install window that just opened, then run this installer again."
fi
ok "command line tools"

# 2. Build and install (a locally built app isn't blocked by Gatekeeper the way a browser download is)
section "building pulse"
note "usually under a minute; longer if your Mac is busy"
spin "compiling…" "compiled" ./scripts/build.sh
osascript -e 'tell application id "local.koz46.pulse" to quit' >/dev/null 2>&1 || true
mkdir -p ~/Applications
rm -rf ~/Applications/Pulse.app
cp -R build.noindex/Pulse.app ~/Applications/Pulse.app
ok "installed to ~/Applications/Pulse.app"

# 3. Claude: exact limits need a Claude Code login; without one Pulse shows tokens used instead.
section "connecting ai tools"
# Several copies of `claude` can be installed and old ones may crash; use the newest that runs.
claude_bin=""; claude_v=""
for c in $(type -ap claude) ~/.nvm/versions/node/*/bin/claude ~/.local/bin/claude /opt/homebrew/bin/claude; do
  [[ -x "$c" ]] || continue
  v=$("$c" --version 2>/dev/null | awk '{print $1}') || continue
  [[ -n "$v" && "$(printf '%s\n%s\n' "$claude_v" "$v" | sort -V | tail -1)" == "$v" ]] && { claude_bin=$c; claude_v=$v; }
done
if [[ -n "$claude_bin" ]]; then
  if ask "connect Claude for exact 5-hour and weekly limits? [Y/n]" y; then
    "$claude_bin" auth login && ok "claude connected" || note "sign-in didn't finish. connect later from Pulse (Connect next to Claude)."
  else
    note "skipped. Pulse shows Claude tokens used until you connect."
  fi
  # Optional: Claude Code status line + agent advisory (edits ~/.claude/settings.json and CLAUDE.md files)
  if ask "add Pulse to Claude Code's status line? edits your Claude settings (backed up). [y/N]" n; then
    /usr/bin/python3 scripts/install-integrations.py >/dev/null && ok "status line added"
  fi
else
  note "Claude Code isn't installed, so Pulse shows Claude tokens used (if any)."
  note "for exact limits later: install Claude Code (https://claude.com/claude-code), then click Connect in Pulse."
fi
defaults write local.koz46.pulse claudeOnboardingDone -bool true  # Already handled here; skip the in-app card.
ok "codex, copilot and gemini are detected automatically"

# 4. Launch
section "launching"
open ~/Applications/Pulse.app
ok "pulse is in your menu bar"

cat <<DONE

  ${D}┌──────────────────────────────────────────────┐${X}
  ${D}│${X}  ${G}done.${X} look for the dials in your menu bar.  ${D}│${X}
  ${D}│${X}                                              ${D}│${X}
  ${D}│${X}  hover    ${D}every ai limit + reset times${X}       ${D}│${X}
  ${D}│${X}  click    ${D}cpu, memory, apps, ai tiles${X}        ${D}│${X}
  ${D}│${X}  •••      ${D}launch at login${X}                    ${D}│${X}
  ${D}└──────────────────────────────────────────────┘${X}
  ${D}more: https://123cheese.co/dev/pulse${X}

DONE
