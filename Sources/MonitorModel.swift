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
    @Published var message: String? { didSet { if message == nil { stuckApp = nil } } }
    @Published var stuckApp: AppUsage? // Set when a normal quit didn't work; the message offers Force Quit.
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    @Published var loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    @Published var menuReadout: String = UserDefaults.standard.string(forKey: "menuReadout") ?? "cpu" {
        didSet { UserDefaults.standard.set(menuReadout, forKey: "menuReadout"); onUpdate?() }
    }
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
    func quit(_ usage: AppUsage) {
        guard canQuit(usage), let app = runningApp(for: usage) else { return }
        stuckApp = nil
        guard app.terminate() else { stuckApp = usage; message = "\(usage.name) didn’t accept the quit request."; return }
        message = "Quit requested. The app may ask you to save your work."
        // A frozen or busy app can ignore a normal quit; offer Force Quit if it is still alive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !app.isTerminated else { return }
            self.stuckApp = usage
            self.message = "\(usage.name) is still running."
        }
    }
    /// Immediate termination, like Activity Monitor's Force Quit. Unsaved work is lost.
    func forceQuit(_ usage: AppUsage) {
        guard canQuit(usage), let app = runningApp(for: usage) else { return }
        stuckApp = nil
        message = app.forceTerminate() ? "\(usage.name) was force quit." : "\(usage.name) couldn’t be force quit. Try Activity Monitor."
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
