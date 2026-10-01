# Pulse implementation plan

Goal: a working native macOS menu bar utility that explains current CPU and memory use.

Design: a monochrome 390pt popover, SF typography, orange graph, compact menu bar percentage. CPU/Memory segmented switch; two-minute live history; top six apps/processes; inline detail selection with process count, PID, resource use, an app-open action, and normal Quit behind confirmation. Never terminate system processes. Activity Monitor opens directly. Launch at login is opt-in. Data stays on device; no dependencies or network calls.

Architecture: a small C bridge reads Mach host counters and libproc process samples. Swift computes interval CPU deltas and groups app helpers by outer app bundle and parentage. A serial sampler polls every three seconds; SwiftUI renders published snapshots on the main thread. AppKit owns a status item and transient popover. Memory pressure comes from the system dispatch source, not inferred from how much RAM is used.

- [x] Test CPU interval math, counter resets, PID reuse, bounded history, grouping and cautious suggestions with a standalone Swift test executable.
- [x] Implement native sampling and validate against real host/process counters in diagnostic mode. Mark unavailable metrics explicitly, exclude inaccessible processes, and explain that totals may differ.
- [x] Implement menu bar/popover, native light/dark appearances, graphs, detail views, Activity Monitor, normal app quit, settings, and VoiceOver labels.
- [x] Package an ad-hoc signed local app, document build/run behavior, run tests and live diagnostics, inspect the running UI, and leave the app available for use.

Validation: compile with installed Xcode; run pure metrics tests; run live sampler diagnostics; launch app; exercise CPU/Memory switching, process details, and Activity Monitor. Preserve other workspace projects.

Review: an independent read-only review identified that quit suggestions must use the same eligibility rules as the Quit action. Fixed by filtering with canQuit and adding an Activity Monitor fallback. Integration testing exposed Apple Silicon Mach tick units; the C bridge now converts with mach_timebase_info and the test matches CLOCK_PROCESS_CPUTIME_ID.

Final validation: 17 Swift metrics checks passed; native process CPU clock agreement was 0.993; host counters passed; final app compiled and signature/plist validated; normal unsandboxed diagnostics returned CPU, memory, pressure, swap, and process data; live native popover rendered and visually inspected at build/preview-live.png. Installed to ~/Applications/Pulse.app. Desktop automation timed out, so actual interaction with tabs, quit confirmation, login registration, and Activity Monitor was not automated; these remain manual acceptance checks.

## 1.1 — colored graphs and visible panel

User screenshot showed the original popover extending above the screen. Replaced automatic popover placement with an explicitly positioned NSPanel constrained below the menu bar inside the active display's visible frame. The root hosting view does not resize the window; display changes recompute bounds. Header, metrics and live graph are pinned; lower app details scroll. Smaller displays use a compact graph and metrics layout. Escape, outside clicks and app deactivation dismiss the panel.

Added a non-template colored live menu bar graph, CPU load color bands with a numeric legend, a blue memory graph, and a main chart that uses the available history width rather than appearing nearly empty on startup.

Validation: 41 unit/placement checks pass across four display layouts and three menu anchor positions. Old fixed placement fails containment checks. Native timing check passes at 1.001 ratio to process CPU clock. Final app builds and signature/plist checks pass. Independent code review returned no substantive findings. Live window capture at build/preview-v1.1.png reports window (342,158,410,704) inside visible screen (57,0,1383,870), fullyVisible=true; the entire header/graph is visible. Native desktop inspection was extremely slow, so follow-up verification used the app's own rendered view and actual NSWindow frame report.
