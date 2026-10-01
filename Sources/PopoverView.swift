import SwiftUI


struct PopoverView: View {
    @ObservedObject var model: MonitorModel
    var panelSize = CGSize(width: 340, height: 560)
    private var compact: Bool { panelSize.height < 500 }
    @State private var quitCandidate: AppUsage?
    @State private var showInfo = false
    @State private var showTip = false
    @State private var showAddKeys = false
    @AppStorage("claudeOnboardingDone") private var claudeOnboardingDone = false
    private var claudeNeedsConnect: Bool { model.accountUsage.first { $0.id == "claude" }?.limiting == nil }
    @AppStorage("panelPinned") private var panelPinned = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var spring: Animation? { reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.14) }
    private var reveal: AnyTransition { reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)) }
    private var isCPU: Bool { model.selectedMetric == .cpu }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    resourceChart(.cpu)
                    Divider().frame(height: 86)
                    resourceChart(.memory)
                }
                accountSummary
                if !claudeOnboardingDone && claudeNeedsConnect { claudeOnboarding }
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider().opacity(0.55)
            ScrollViewReader { proxy in
              ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    guidance
                    apps.id("apps-top")
                    if let selected = model.selectedApp { detail(selected).id("app-detail").transition(reveal) }
                    else if model.selectedAppID != nil {
                        Text("This app is no longer running.").font(.callout).foregroundStyle(.secondary)
                    }
                    if model.selectedApp == nil, let message = model.message { messageRow(message) }
                    if showInfo { information.transition(reveal) }
                }.padding(.horizontal, 16).padding(.vertical, 10)
                  .animation(spring, value: model.selectedAppID)
                  .animation(spring, value: showInfo)
              }.onChange(of: model.selectedAppID) { _, value in
                  withAnimation(spring) {
                      if value != nil { proxy.scrollTo("app-detail", anchor: .bottom) }
                      else { proxy.scrollTo("apps-top", anchor: .top) }
                  }
              }
            }
            Divider().opacity(0.55)
            footer
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(PanelGlass())
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .tint(.primary)
    }

    private func messageRow(_ message: String) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(message).font(.system(size: 11))
            Spacer(minLength: 0)
            if let stuck = model.stuckApp {
                Button("Force Quit") { model.forceQuit(stuck) }.controlSize(.small).tint(.red)
            }
            Button { model.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Dismiss message")
        }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Text("Pulse").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(Color.secondary).frame(width: 5, height: 5)
                Text(model.snapshot == nil ? "CONNECTING" : "LIVE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1.3)
            }.foregroundStyle(.secondary).accessibilityElement(children: .combine)
            Button { panelPinned.toggle() } label: {
                Image(systemName: panelPinned ? "pin.fill" : "pin")
                    .font(.system(size: 12)).foregroundStyle(panelPinned ? .primary : .secondary)
                    .animation(spring, value: panelPinned)
            }.buttonStyle(.plain)
             .help(panelPinned ? "Pinned · stays open when switching apps" : "Pin to keep open")
             .accessibilityLabel(panelPinned ? "Unpin panel" : "Pin panel")
            Menu {
                Picker("Menu bar", selection: $model.menuReadout) {
                    Text("CPU").tag("cpu")
                    Text("Memory").tag("memory")
                    Text("CPU + Memory").tag("both")
                }
                Divider()
                Button(model.loginEnabled ? "✓ Launch at login" : model.loginNeedsApproval ? "Launch at login · approval required" : "Launch at login") { model.toggleLogin() }
                Button(showInfo ? "Hide how readings work" : "How readings work") { showInfo.toggle() }
                Divider()
                Button("Quit Pulse", role: .destructive) { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 16)).foregroundStyle(.secondary) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 26)
            .accessibilityLabel("Pulse settings")
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func resourceChart(_ metric: MonitorModel.Metric) -> some View {
        let cpu = metric == .cpu
        let values = cpu ? model.cpuHistory.values : model.memoryHistory.values
        let value = values.last.map { "\(Int($0.rounded()))%" } ?? "—"
        return Button { model.selectedMetric = metric } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(cpu ? "CPU" : "Memory").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.selectedMetric == metric ? .primary : .secondary)
                    Spacer(minLength: 0)
                    if model.selectedMetric == metric { SelectedPulse(color: cpu ? .teal : .blue) }
                }.foregroundStyle(.secondary)
                Text(value).font(.system(size: 24, weight: .medium)).monospacedDigit()
                Sparkline(values: values, isCPU: cpu, replay: model.panelOpens).frame(height: compact ? 32 : 44)
                Text(cpu ? "Whole CPU · last 2 min" : "Pressure: \(model.pressureText)")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
         .help(cpu ? "Show apps ranked by CPU" : "Show apps ranked by memory")
         .accessibilityLabel("\(cpu ? "CPU" : "Memory"), \(value). Show apps using the most.")
    }

    private func stat(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit()
        }
    }

    /// One-time first-run card: exact Claude limits need a Claude Code login.
    private var claudeOnboarding: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect Claude for exact limits").font(.system(size: 11, weight: .semibold))
            Text("Sign in to Claude Code once and Pulse shows your 5-hour and weekly %. Until then it shows tokens used.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Terminal") { model.connectClaude(); claudeOnboardingDone = true }.controlSize(.small)
                Button("Not now") { claudeOnboardingDone = true }.controlSize(.small).buttonStyle(.borderless)
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
         .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Every connected AI tool as a tile; tap to pin up to three to the menu bar.
    private var accountSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                ForEach(model.accountUsage) { provider in providerTile(provider) }
                addTile
            }
            if claudeNeedsConnect && claudeOnboardingDone {
                Button("Connect Claude for exact %") { model.connectClaude() }.buttonStyle(.link).font(.system(size: 10))
            }
        }.padding(.top, 2)
    }

    private func providerTile(_ provider: ProviderUsage) -> some View {
        let isPinned = model.pinned.contains(provider.id)
        return Button { model.togglePin(provider.id) } label: {
            HStack(spacing: 5) {
                Image(nsImage: providerDial(provider.id, used: provider.limiting?.usedPercent))
                    .resizable().frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(provider.name).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                    // The caption names the limit behind the number, e.g. "83% 5h".
                    (Text(provider.valueText).font(.system(size: 11, weight: .medium))
                     + Text(provider.valueCaption.map { " " + $0 } ?? "").font(.system(size: 9)).foregroundColor(.secondary))
                        .monospacedDigit().lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(5).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(isPinned ? 0.09 : 0.03), in: RoundedRectangle(cornerRadius: 7))
            .overlay(alignment: .topTrailing) {
                if isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 7)).foregroundStyle(.secondary).padding(4)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.45), value: isPinned)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
         .help(provider.summary + (isPinned ? "\nClick to unpin from the menu bar" : model.pinned.count < 3 ? "\nClick to pin to the menu bar" : "\nUnpin another tool to pin this one (max 3)"))
         .accessibilityLabel("\(provider.name), \(provider.valueText) \(provider.valueCaption ?? ""). \(isPinned ? "Pinned" : "Not pinned")")
    }

    private var addTile: some View {
        Button { showAddKeys.toggle() } label: {
            Label("Add", systemImage: "plus").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
         .help("Add API spend tracking")
         .popover(isPresented: $showAddKeys, arrowEdge: .bottom) { AddKeysView(model: model) }
    }

    private var needsAttention: Bool {
        model.pressure == 2 || model.pressure == 4 || (model.snapshot?.cpu ?? 0) >= 85
    }

    private var guidance: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: needsAttention ? "exclamationmark.circle" : "checkmark.circle")
                .font(.system(size: 12)).foregroundStyle(needsAttention ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.headline).font(.system(size: 11, weight: .medium))
                if needsAttention {
                    Text(model.advice).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }.help(model.advice).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var apps: some View {
        VStack(spacing: 3) {
            HStack {
                Text("USING THE MOST").tracking(1.3)
                Spacer()
                Text(isCPU ? "% CPU" : "MEMORY").tracking(0.8)
            }.font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary).padding(.bottom, 7)
            if model.snapshot?.processError == true {
                Text("Process readings aren’t available. Open Activity Monitor for details.").font(.callout).foregroundStyle(.secondary)
            } else if model.sortedApps.isEmpty {
                Text("Reading running apps…").font(.callout).foregroundStyle(.secondary).padding(.vertical, 25)
            } else {
                ForEach(Array(model.sortedApps.prefix(5))) { app in
                    Button { model.selectedAppID = model.selectedAppID == app.id ? nil : app.id } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: model.icon(for: app)).resizable().scaledToFit().frame(width: 18, height: 18).saturation(0)
                            Text(app.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(isCPU ? String(format: "%.1f", app.cpu) : formatBytes(app.memory))
                                .font(.system(size: 11, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                        }.padding(.horizontal, 4).padding(.vertical, 5)
                            .contentShape(Rectangle())
                            .background(model.selectedAppID == app.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(RowButtonStyle())
                    .accessibilityLabel("\(app.name), \(isCPU ? String(format: "%.1f percent CPU", app.cpu) : formatBytes(app.memory)). Show details")
                }
            }
            Text(isCPU ? "App CPU: 100% = one core. Helpers are grouped." : "Physical footprint · app helpers are grouped.")
                .font(.system(size: 9)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
        }
    }

    private func detail(_ app: AppUsage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { model.selectedAppID = nil } label: {
                Label("Back to apps", systemImage: "chevron.left").font(.system(size: 11))
            }.buttonStyle(.plain).foregroundStyle(.secondary)
            Text(app.name).font(.system(size: 13, weight: .semibold))
            HStack {
                stat("CPU", value: String(format: "%.1f%%", app.cpu))
                Spacer()
                stat("Memory", value: formatBytes(app.memory))
                Spacer()
                stat("Processes", value: String(app.pids.count))
            }
            Text("PID \(app.pids.sorted().prefix(8).map(String.init).joined(separator: ", "))\(app.pids.count > 8 ? " + more" : "")")
                .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            if quitCandidate?.id == app.id {
                // Inline confirm: alerts don't reliably appear over a borderless menu-bar panel.
                HStack {
                    Text("Quit \(app.name)?").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Cancel") { quitCandidate = nil }.controlSize(.small)
                    Button("Quit") { model.quit(app); quitCandidate = nil }.controlSize(.small)
                    Button("Force Quit") { model.forceQuit(app); quitCandidate = nil }.controlSize(.small).tint(.red)
                        .help("Stops it immediately. Unsaved work is lost.")
                }
            } else {
            HStack {
                if model.runningApp(for: app) != nil {
                    Button("Show app") { model.openApp(app) }.controlSize(.small)
                }
                // Always shown so it never looks missing; disabled with a reason when quitting isn't allowed.
                Button("Quit \(app.name)…") { quitCandidate = app }.controlSize(.small)
                    .disabled(!model.canQuit(app))
                    .help(model.canQuit(app) ? "Ask \(app.name) to quit"
                          : model.runningApp(for: app) == nil ? "Background process · inspect it in Activity Monitor"
                          : "macOS keeps \(app.name) running, so Pulse can't quit it")
                Spacer()
                // Guidance stays one click away instead of always taking space.
                Button { showTip.toggle() } label: {
                    Image(systemName: "questionmark.circle").font(.system(size: 14)).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                 .accessibilityLabel("Tips for this app")
                 .popover(isPresented: $showTip, arrowEdge: .bottom) {
                    Text(app.appPath == nil ? "This is a background process. Inspect it in Activity Monitor before taking action." : "If you don’t need this app, save your work before quitting. Closing unused windows can also reduce its workload.")
                        .font(.system(size: 11)).frame(width: 220).fixedSize(horizontal: false, vertical: true).padding(10)
                 }
            }
            }
            if let message = model.message { messageRow(message) }
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(model.accountUsage) { provider in Text(provider.summary) }
            Text("Allowance guidance: conserve at 80%; pause optional work at 95%. These are advisory thresholds.")
            Text("A small window into your Mac").font(.system(size: 12, weight: .semibold))
            Text("Updates every 3 seconds. History starts when Pulse opens and stays in memory. CPU above 100% for an app means it’s using more than one core. Memory is estimated from macOS counters. App memory uses macOS physical footprint, including compressed allocations. Helpers are grouped; compare with their combined Activity Monitor rows. CPU samples cover a 3-second interval, so refresh timing can differ. Suggestions reflect the current sample, not a diagnosis.")
            Text("\(model.snapshot?.skipped ?? 0) processes could not be read. macOS restricts some process details. All readings stay on this Mac.")
        }.font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack {
            Button { model.openActivityMonitor() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open Activity Monitor")
                }.font(.system(size: 11, weight: .medium))
            }.buttonStyle(.plain).keyboardShortcut("a", modifiers: .command)
            Spacer()
            Text("EVERY 3s").font(.system(size: 8, design: .monospaced)).tracking(0.7).foregroundStyle(.secondary)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct Sparkline: View {
    let values: [Double]
    let isCPU: Bool
    var replay = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress: CGFloat = 0
    private var color: Color { isCPU ? ((values.last ?? 0) >= 85 ? .orange : .teal) : .blue }
    var body: some View {
        HStack(spacing: 4) {
            scale.frame(width: 24)
            plot
        }
        .font(.system(size: 8)).monospacedDigit().foregroundStyle(.secondary)
        .onAppear { draw() }
        .onChange(of: values.isEmpty) { _, empty in if !empty { draw() } }
        // The panel is reused between opens, so redraw the line each time it opens.
        .onChange(of: replay) { _, _ in
            guard !reduceMotion else { return }
            progress = 0
            DispatchQueue.main.async { draw() }
        }
        .onChange(of: reduceMotion) { _, reduce in if reduce { progress = 1 } }
    }
    /// Scale labels sitting on the 100 / 50 / 0 gridlines.
    private var scale: some View {
        GeometryReader { geometry in
            ForEach([100, 50, 0], id: \.self) { (percent: Int) in
                let y: CGFloat = 3 + CGFloat(100 - percent) / 100 * (geometry.size.height - 6)
                Text(percent == 0 ? "0" : "\(percent)%").position(x: geometry.size.width / 2, y: y)
            }
        }
    }

    private var plot: some View {
        let shown: CGFloat = reduceMotion ? 1 : progress
        return ZStack {
            GridLines().stroke(.secondary.opacity(0.2), style: StrokeStyle(lineWidth: 0.5, dash: [2, 4]))
            // Shading below the line reads as a fill level, e.g. 83% ≈ mostly full.
            HistoryLine(values: values, closed: true).fill(color.opacity(0.15)).opacity(shown)
            HistoryLine(values: values).trim(from: 0, to: shown)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
    }

    private func draw() {
        guard !values.isEmpty else { return }
        if reduceMotion { progress = 1 }
        else { withAnimation(.easeOut(duration: 0.45)) { progress = 1 } }
    }
}

/// Marks the chart that ranks the app list: a bright colored dot with a ring.
/// Static on purpose: a looping animation would redraw the panel every frame.
private struct SelectedPulse: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7)
            .overlay(Circle().stroke(color.opacity(0.4), lineWidth: 1.5).frame(width: 12, height: 12))
            .padding(.trailing, 2)
            .accessibilityHidden(true)
    }
}

private struct GridLines: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for fraction in [0.0, 0.5, 1.0] {
            let y = 3 + fraction * (rect.height - 6)
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }
}

private struct HistoryLine: Shape {
    let values: [Double]
    var closed = false // Close down to the 0 gridline for area shading.
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = 2 + (rect.width - 4) * CGFloat(index) / CGFloat(max(1, values.count - 1))
            let y = 3 + (rect.height - 6) * (1 - CGFloat(min(100, max(0, value))) / 100)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if closed, let last = path.currentPoint, !values.isEmpty {
            path.addLine(to: CGPoint(x: last.x, y: rect.height - 3))
            path.addLine(to: CGPoint(x: 2, y: rect.height - 3))
            path.closeSubpath()
        }
        return path
    }
}

private struct PanelGlass: NSViewRepresentable {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func makeNSView(context: Context) -> NSVisualEffectView { NSVisualEffectView() }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.backgroundColor = reduceTransparency ? NSColor.windowBackgroundColor.cgColor : nil
    }
}

/// Admin API keys for month-to-date spend. Gemini CLI, Copilot, Claude and Codex are detected automatically.
private struct AddKeysView: View {
    @ObservedObject var model: MonitorModel
    @State private var openAI = ""
    @State private var anthropic = ""
    @State private var status: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add AI usage").font(.system(size: 12, weight: .semibold))
            Text("Claude Code, Codex, Gemini CLI and GitHub Copilot appear automatically when installed. For API spend this month, paste an admin key. Keys are stored in your Keychain.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("OpenAI admin key (sk-admin-…)", text: $openAI)
            SecureField("Anthropic admin key (sk-ant-admin…)", text: $anthropic)
            HStack {
                if let status { Text(status).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Button("Save") {
                    // Only fields with something typed are saved; an untouched field keeps its existing key.
                    let saved = [("openai", openAI), ("anthropic", anthropic)].filter { !$0.1.isEmpty }.map { model.saveKey($0.0, key: $0.1) }
                    status = saved.isEmpty ? "Nothing to save" : saved.allSatisfy { $0 } ? "Saved · appears within a minute" : "That doesn't look like a key"
                    openAI = ""; anthropic = ""
                }.controlSize(.small).keyboardShortcut(.defaultAction)
            }
        }.textFieldStyle(.roundedBorder).font(.system(size: 11)).padding(12).frame(width: 260)
    }
}
