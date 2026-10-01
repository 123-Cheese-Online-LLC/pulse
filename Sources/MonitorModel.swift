import AppKit
import SwiftUI
import ServiceManagement

@MainActor
final class MonitorModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var accountUsage: [ProviderUsage] = []
    private let accounts = AccountUsage()
    @Published var cpuHistory = History()
    @Published var memoryHistory = History()
    @Published var selectedMetric: Metric = .cpu
    @Published var selectedAppID: String?
    @Published var panelOpens = 0 // Bumped on each open so charts replay their draw-in.
    @Published var message: String? { didSet { if message == nil { stuckApp = nil } } }
    @Published var stuckApp: AppUsage? // Set when a normal quit didn't work; the message offers Force Quit.
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var menuReadout: String = UserDefaults.standard.string(forKey: "menuReadout") ?? "cpu" {
        didSet { UserDefaults.standard.set(menuReadout, forKey: "menuReadout"); onUpdate?() }
    }
    /// Up to three providers shown as dials in the menu bar.
    @Published var pinned: [String] = UserDefaults.standard.stringArray(forKey: "pinnedProviders") ?? ["claude", "codex"] {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinnedProviders"); onUpdate?() }
    }
    func togglePin(_ id: String) {
        if let index = pinned.firstIndex(of: id) { pinned.remove(at: index) }
        else if pinned.count < 3 { pinned.append(id) }
    }
    func saveKey(_ provider: String, key: String) -> Bool { accounts.saveKey(provider, key: key) }
    var menuMetric: Metric { menuReadout == "memory" ? .memory : .cpu }
    var onUpdate: (() -> Void)?
    private let queue = DispatchQueue(label: "app.pulse.sampler", qos: .utility)
    private let sampler = Sampler()
    private var timer: DispatchSourceTimer?
    private var pressureSource: DispatchSourceMemoryPressure?
    private var observedPressure: Int?
    private var icons: [String: NSImage] = [:]

    enum Metric: String, CaseIterable {
        case cpu, memory
        var label: String { self == .cpu ? "CPU" : "Memory" }
    }

    func start() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            self.observedPressure = source.data.contains(.critical) ? 4 : source.data.contains(.warning) ? 2 : 1
        }
        pressureSource = source
        source.resume()
        let sampler = self.sampler
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            let snapshot = sampler.sample()
            DispatchQueue.main.async { self?.accept(snapshot) }
        }
        self.timer = timer
        timer.resume()
    }

    func accept(_ snapshot: Snapshot) {
        if let previous = self.snapshot, snapshot.date.timeIntervalSince(previous.date) > 9 {
            cpuHistory = History()
            memoryHistory = History()
        }
        self.snapshot = snapshot
        if let cpu = snapshot.cpu { cpuHistory.append(cpu) }
        if let used = snapshot.memoryUsed, snapshot.memoryTotal > 0 {
            memoryHistory.append(Double(used) / Double(snapshot.memoryTotal) * 100)
        }
        accounts.refreshIfNeeded()
        accountUsage = accounts.read()
        accounts.publish(snapshot, providers: accountUsage, pressure: pressure, cpuHistory: cpuHistory.values)
        if let error = accounts.writeError { message = error }
        onUpdate?()
    }

    var pressure: Int { observedPressure ?? snapshot?.pressure ?? -1 }
    var pressureText: String {
        switch pressure { case 1: "Normal"; case 2: "Elevated"; case 4: "High"; default: "Unavailable" }
    }
    var sortedApps: [AppUsage] {
        guard let snapshot else { return [] }
        return snapshot.apps.sorted {
            let a = selectedMetric == .cpu ? $0.cpu : Double($0.memory)
            let b = selectedMetric == .cpu ? $1.cpu : Double($1.memory)
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a > b
        }
    }
    var selectedApp: AppUsage? { snapshot?.apps.first { $0.id == selectedAppID } }
    var menuTitle: String {
        let cpu = snapshot?.cpu.map { "CPU \(Int($0.rounded()))%" } ?? "CPU —"
        let memory: String
        if let snapshot, let used = snapshot.memoryUsed, snapshot.memoryTotal > 0 {
            memory = "MEM \(Int((Double(used) / Double(snapshot.memoryTotal) * 100).rounded()))%"
        } else { memory = "MEM —" }
        return menuReadout == "both" ? cpu + "  " + memory : menuReadout == "memory" ? memory : cpu
    }

    var headline: String {
        guard let snapshot, let cpu = snapshot.cpu else { return "Getting a reading" }
        if pressure == 4 { return "Memory needs room" }
        if pressure == 2 { return "Memory is under pressure" }
        if cpu >= 85 { return "Your Mac is working hard" }
        return "Room to breathe"
    }
    var advice: String {
        guard let snapshot, snapshot.cpu != nil else { return "Your first live reading will arrive in a few seconds." }
        let apps = snapshot.apps.filter { canQuit($0) }
        if pressure == 2 || pressure == 4 {
            if let largest = apps.max(by: { $0.memory < $1.memory }) {
                return "\(largest.name) uses \(formatBytes(largest.memory)). If you’re finished with it, save your work and quit it to make room."
            }
            return "Memory is under pressure. Open Activity Monitor to inspect it; no app available for a normal quit is using measurable memory."
        }
        if let busiest = apps.max(by: { $0.cpu < $1.cpu }), busiest.cpu > 60 {
            return "\(busiest.name) is busiest right now. If that’s unexpected, pause its work or close unused windows."
        }
        if (snapshot.cpu ?? 0) >= 85 {
            return "CPU use is high. Check the top processes in Activity Monitor before closing anything."
        }
        return "Nothing needs closing right now. Select an app below for a closer look."
    }
    func icon(for app: AppUsage) -> NSImage {
        guard let path = app.appPath else { return NSImage(systemSymbolName: "gearshape", accessibilityDescription: "System process")! }
        if let cached = icons[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
    func runningApp(for usage: AppUsage) -> NSRunningApplication? {
        guard let path = usage.appPath else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path == path && $0.activationPolicy == .regular }
    }
    func canQuit(_ usage: AppUsage) -> Bool {
        guard let app = runningApp(for: usage) else { return false }
        return app.processIdentifier != ProcessInfo.processInfo.processIdentifier && app.bundleIdentifier != "com.apple.finder"
    }
    func connectClaude() { accounts.connectClaude() }
    func openApp(_ usage: AppUsage) { runningApp(for: usage)?.activate() }
    /// What stopping this row would do. Apps quit normally, Finder relaunches, and background
    /// processes can be stopped only when they're yours and not part of the login session.
    enum StopAction: Equatable { case app, relaunchFinder, process, blocked(String) }
    /// Your own processes that the session depends on: stopping them logs you out, freezes input,
    /// or loses settings, even though macOS would restart some of them.
    private static let sessionCritical: Set<String> = ["loginwindow", "WindowServer", "launchd", "kernel_task", "logd", "UserEventAgent",
                                                       "backboardd", "cfprefsd", "distnoted", "secd", "trustd", "lsd", "coreservicesd"]
    func stopAction(_ usage: AppUsage) -> StopAction {
        if let app = runningApp(for: usage) {
            if app.processIdentifier == getpid() { return .blocked("Use ••• → Quit Pulse") }
            return app.bundleIdentifier == "com.apple.finder" ? .relaunchFinder : .app
        }
        if Self.sessionCritical.contains(usage.name) { return .blocked("macOS needs \(usage.name) for your session · stopping it could log you out or freeze input") }
        if usage.pids.contains(getpid()) { return .blocked("Use ••• → Quit Pulse") }
        for pid in usage.pids {
            let owner = pulse_owner(pid, nil)
            // Unreadable means gone, or a process macOS won't even let us inspect (always someone else's).
            if owner < 0 { return kill(pid, 0) == 0 || errno == EPERM ? .blocked("System process · macOS protects it") : .blocked("It has already exited") }
            if owner != Int32(getuid()) { return .blocked("System process · macOS protects it") }
        }
        return usage.pids.isEmpty ? .blocked("Nothing to stop") : .process
    }
    /// Signals each process, re-checking right before that the pid is still ours and, when the row
    /// recorded a start time, still the same process (pids get reused).
    private func signal(_ usage: AppUsage, _ sig: Int32) -> Bool {
        let recordedStart = usage.id.hasPrefix("pid:") ? UInt64(usage.id.split(separator: ":").last ?? "") : nil
        var sent = false
        for pid in usage.pids {
            var start: UInt64 = 0
            guard pulse_owner(pid, &start) == Int32(getuid()), recordedStart == nil || recordedStart == start else { continue }
            if kill(pid, sig) == 0 { sent = true }
        }
        return sent
    }
    private func alive(_ usage: AppUsage) -> Bool { usage.pids.contains { pulse_owner($0, nil) == Int32(getuid()) } }

    func quit(_ usage: AppUsage) {
        stuckApp = nil
        switch stopAction(usage) {
        case .app:
            guard let app = runningApp(for: usage) else { return }
            guard app.terminate() else { stuckApp = usage; message = "\(usage.name) didn’t accept the quit request."; return }
            message = "Quit requested. The app may ask you to save your work."
            // A frozen or busy app can ignore a normal quit; offer Force Quit if it is still alive.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, !app.isTerminated else { return }
                self.stuckApp = usage
                self.message = "\(usage.name) is still running."
            }
        case .relaunchFinder:
            message = runningApp(for: usage)?.forceTerminate() == true ? "Finder is relaunching." : "Finder couldn’t be relaunched. Try Activity Monitor."
        case .process:
            guard signal(usage, SIGTERM) else { message = "\(usage.name) had already exited."; return }
            message = "Asked \(usage.name) to stop."
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                guard let self, self.alive(usage) else { return }
                self.stuckApp = usage
                self.message = "\(usage.name) is still running."
            }
        case .blocked(let reason):
            message = reason
        }
    }
    /// Immediate termination, like Activity Monitor's Force Quit. Unsaved work is lost.
    func forceQuit(_ usage: AppUsage) {
        stuckApp = nil
        switch stopAction(usage) {
        case .app, .relaunchFinder:
            guard let app = runningApp(for: usage) else { return }
            message = app.forceTerminate() ? "\(usage.name) was force quit." : "\(usage.name) couldn’t be force quit. Try Activity Monitor."
        case .process:
            message = signal(usage, SIGKILL) ? "\(usage.name) was force quit." : "\(usage.name) had already exited."
        case .blocked(let reason):
            message = reason
        }
    }
    func openActivityMonitor() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor") else {
            message = "Activity Monitor couldn’t be found in Applications → Utilities."
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { self.message = error.localizedDescription } }
        }
    }
    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else { try SMAppService.mainApp.register() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
            if loginNeedsApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { message = "Couldn’t change launch at login: \(error.localizedDescription)" }
    }
}
