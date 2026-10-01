# Pulse changelog

Development notes per version, newest last. See the README for how to install and use Pulse.

## Reading the numbers

The main CPU number is the percentage of total processor capacity. Per-app CPU follows Activity Monitor’s convention: 100% equals one core, so multicore work can exceed 100%. Readings are interval deltas, not lifetime averages. libproc’s Mach ticks are converted to nanoseconds using the host timebase.

System memory is estimated from internal, purgeable, wired, and compressed page counters. Per-app memory is the sum of resident sizes, which can double-count shared pages and differ from Activity Monitor’s memory footprint. Memory pressure comes from macOS, never from the amount of occupied RAM alone. Some protected processes cannot be read; the information section shows the number skipped. Those processes still contribute to the overall CPU and memory totals.

Recommendations are simple observations of the current sample. They cannot know whether an app’s workload is intentional. Pulse never closes anything automatically. The Activity Monitor link opens the app; it does not automate its search field or select a process.

## Verification

```sh
./scripts/test.sh
build.noindex/Pulse.app/Contents/MacOS/Pulse --diagnose
```

The tests cover CPU deltas, zero intervals, counter resets, PID reuse, helper grouping, parent cycles, bounded history, and panel containment across short and multiple-display layouts. A native integration check compares process CPU measurements against `CLOCK_PROCESS_CPUTIME_ID` under a brief CPU workload, and validates host memory counters.

Diagnostic mode prints two live samples three seconds apart. Development sandboxes may block swap, memory pressure, process access, or Launch Services; the normally launched app is not App Sandbox restricted.

For a rendered inspection of the live popover:

```sh
open build.noindex/Pulse.app --args --capture /tmp/pulse-preview.png
```

The capture instance exits after writing its own view to PNG. Close any running Pulse instance before using this option.

## 1.2 — account dials and agent awareness

Separate Codex and Claude ring dials in the macOS menu bar show **account allowance used**, using the most-used currently reported window. They are not CPU or context-window percentages. Hover for the window/reset time; click to open Pulse. Empty menu-bar rings mean unknown, never zero; the expanded percentage shows a dash. Samples older than 15 minutes or past reset are not displayed as current.

Codex refreshes every five minutes through its installed CLI's read-only `account/rateLimits/read` method. It never starts a model turn, spends reset credits, or purchases anything. Claude Code's status-line callback writes only usage windows and a timestamp, using its existing response metadata. Claude's dial begins reporting after Claude Code provides usage on a response; Claude Desktop alone does not supply this callback. No prompts, transcripts, credentials, or account IDs are saved by Pulse.

Pulse writes `~/Library/Application Support/Pulse/agent-status.json` every sample. `continue`, `conserve` (80% account use), `pause` (95%), and `unknown` are advisory. Critical memory pressure advises pausing extra heavy work; elevated pressure or sustained CPU above 90% advises conserving. Existing tasks are not remotely stopped. Codex and Claude instruction files point agents to this file before expensive work. Machine advice expires after 15 seconds; provider readings have their own freshness checks.

The Claude integration preserves other settings and backs up the original settings file. To remove it, remove the Pulse `statusLine` entry from `~/.claude/settings.json`, and the marked PULSE USAGE ADVISORY blocks from `~/.codex/AGENTS.md` and `~/.claude/CLAUDE.md`.

Source contracts: [Codex app-server](https://developers.openai.com/codex/app-server/), [Claude Code status line](https://code.claude.com/docs/en/statusline).

## 1.3 — compact appearance

Smaller monochrome Pulse branding, tighter menu-bar items, five ranked apps, and one concise account row. Reset times stay in hover help and expanded information. UI and icons are monochrome; only charts and attention indicators use color. Warning dials use amber rather than red.

## 1.4 — logo dials and glass

The compact menu bar shows two monochrome app-logo dials and a CPU sparkline with its percentage. Click to expand account percentages and resource details. App details use a labeled Back to apps control and a separate Quit [app name] button with confirmation. The panel uses native translucent material and respects Reduce Transparency. Pulse includes a monochrome waveform Applications icon.

## 1.6 — two charts and memory footprint

CPU and Memory have separate charts in the panel and in the CPU + Memory menu-bar mode. Click a panel chart to rank apps by that metric. Chart entrances draw the stroke; Reduce Motion shows the completed line immediately.

Per-app memory now uses proc_pid_rusage physical footprint, matching the metric used by Activity Monitor rather than resident size. Helpers remain grouped, and 3-second CPU sampling may differ from Activity Monitor refresh timing. Processes whose footprint cannot be read count as skipped rather than mixing resident and footprint totals. A clean mapped-file regression test reproduces the old resident-size discrepancy and checks the corrected result against TASK_VM_INFO.

## 1.7 — Claude limits from the desktop app, clearer chart selection

The status-line callback only runs in Claude Code in Terminal, so Claude's dial stayed empty for desktop-app use. Every five minutes, alongside Codex, Pulse now reads the 5-hour and weekly limits that `/usage` shows. It uses Claude Code's saved login from the macOS Keychain (`Claude Code-credentials`). The token is sent only to Anthropic and is never stored, printed, or refreshed; refreshing could sign Claude Code out. If that login has expired, Pulse says so: run `claude` in Terminal once to renew it. The endpoint is unofficial and may change.

The selected CPU or Memory chart shows a dot in the chart's color with a pulsing ring; Reduce Motion keeps it still.

Hovering over the menu bar item shows a quick card with every Claude and Codex limit (bar, percent, reset time) plus CPU and memory; it replaces the slower system tooltip. CPU and Memory charts have a 0 / 50 / 100% scale, shading under the line, and "last 2 min" in the caption. In app details, the quit guidance sits behind a ? button.

Quit is confirmed inline in the app card (Cancel · Quit · Force Quit); alerts didn't reliably appear over the borderless panel. If a normal quit hasn't finished after 4 seconds, Pulse offers Force Quit.

Lightweight: about 1% of one core while closed (was 13–34%). Process names use string ops instead of `URL(fileURLWithPath:)`, which hit the disk for every process every sample. The panel is built once and detached while hidden (no work, ~10 ms reopen, no fade-in), and the selected-chart marker is static rather than a looping animation.

Claude readings, best first: (1) exact 5-hour/weekly % from Anthropic when Claude Code's login is valid (read-only; Pulse never refreshes or edits the login), (2) otherwise tokens used in the last 5 hours / 7 days, counted from Claude Code's local session logs in `~/.claude/projects` (desktop and Terminal sessions; no login needed; only usage numbers are read). Anthropic doesn't publish the limits, so the fallback can't show a percentage.

## AI usage matrix

Every connected AI tool gets a tile in a 3-column grid; click a tile to pin it (up to three pinned tools become the menu bar dials). Hover the menu bar for every tool's limits.

| Tool | Shows | How it's read |
|---|---|---|
| Claude Code | 5-hour / weekly % (or tokens used) | Claude Code login, read-only; fallback: local session logs |
| Codex | 5-hour / weekly % | Codex CLI's read-only `account/rateLimits/read` |
| Gemini CLI | Tokens last 5h / 7 days | Local session files in `~/.gemini/tmp` |
| GitHub Copilot | Chat / completions / premium quota % | `gh api /copilot_internal/user` (unofficial) |
| OpenAI API | $ this month | Costs API with an admin key (Pulse → Add) |
| Anthropic API | $ this month | Cost API with an admin key (Pulse → Add) |

Tools appear automatically once they're set up. Admin keys are stored in the macOS Keychain. Adding a tool means adding one reader function to `Integrations/usage_bridge.py` and registering it in `PROVIDERS`.

Check what Pulse can read on a Mac (prints no secrets):

```sh
/usr/bin/python3 ~/Applications/Pulse.app/Contents/Resources/usage_bridge.py status
```
