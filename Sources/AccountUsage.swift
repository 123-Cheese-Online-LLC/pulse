import Foundation
import AppKit

struct UsageWindow: Codable {
    let label: String
    let usedPercent: Double
    let resetsAt: Double
}
struct UsageRecord: Codable {
    let updatedAt: Double
    let windows: [UsageWindow]
    var note: String? = nil // Why there is no exact reading, e.g. no Claude Code login.
    var local: LocalTokens? = nil // Fallback when no % is available.
}
struct LocalTokens: Codable {
    let fiveHourTokens: Int
    let weekTokens: Int
    var text: String { "\(compactTokens(fiveHourTokens)) tokens last 5h · \(compactTokens(weekTokens)) this week" }
}
func compactTokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1_000 ? "\(n / 1_000)K" : "\(n)"
}
struct ProviderUsage: Identifiable {
    let id: String
    let record: UsageRecord?
    var name: String { id == "codex" ? "Codex" : "Claude" }
    var activeWindows: [UsageWindow] {
        let now = Date().timeIntervalSince1970
        guard let record, now - record.updatedAt < 900, record.updatedAt <= now + 60 else { return [] }
        return record.windows.filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt > now }
    }
    /// Local token counts, only while the record is fresh.
    var localTokens: LocalTokens? {
        guard let record, Date().timeIntervalSince1970 - record.updatedAt < 900 else { return nil }
        return record.local
    }
    var limiting: UsageWindow? { activeWindows.max { $0.usedPercent < $1.usedPercent } }
    var recommendation: String {
        guard let used = limiting?.usedPercent else { return "unknown" }
        return used >= 95 ? "pause" : used >= 80 ? "conserve" : "continue"
    }
    var summary: String {
        guard let window = limiting else {
            if let local = localTokens { return "\(name): \(local.text)" }
            if let note = record?.note { return "\(name): \(note)" }
            return id == "claude" ? "Waiting for Claude Code · no current usage reading" : "No current Codex usage reading"
        }
        let reset = Date(timeIntervalSince1970: window.resetsAt).formatted(date: .abbreviated, time: .shortened)
        return "\(name): \(Int(window.usedPercent))% used · \(window.label) · resets \(reset) · \(recommendation)"
    }
}

final class AccountUsage {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pulse") }
    private var process: Process?
    private var lastRefresh = Date.distantPast
    private var fastUntil = Date.distantPast // After Connect, poll every 30s for 5 min to pick up the new login.
    var writeError: String?

    func read() -> [ProviderUsage] {
        ["codex", "claude"].map { name in
            let url = Self.directory.appendingPathComponent("\(name)-usage.json")
            let record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(UsageRecord.self, from: $0) }
            return ProviderUsage(id: name, record: record)
        }
    }
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefresh) >= (Date() < fastUntil ? 30 : 300), process?.isRunning != true,
              let script = Bundle.main.url(forResource: "usage_bridge", withExtension: "py") else { return }
        lastRefresh = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path, "refresh"] // Codex + Claude limits
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); process = task } catch { process = nil }
    }
    /// Opens Terminal to sign Claude Code in; Pulse reads exact limits once that login exists.
    func connectClaude() {
        let script = Self.directory.appendingPathComponent("connect-claude.command")
        let body = """
        #!/bin/zsh -l
        command -v claude >/dev/null || { echo "Claude Code isn't installed. Get it at https://claude.com/claude-code"; exit 1; }
        claude auth login && echo "\nDone. Pulse will show exact Claude limits within a minute. You can close this window."
        """
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)) != nil else { return }
        NSWorkspace.shared.open(script) // .command files open in Terminal without extra permissions.
        fastUntil = Date().addingTimeInterval(300)
        lastRefresh = .distantPast
    }
    func publish(_ snapshot: Snapshot, providers: [ProviderUsage], pressure: Int, cpuHistory: [Double]) {
        let sustainedCPU = cpuHistory.count >= 10 && cpuHistory.suffix(10).allSatisfy { $0 >= 90 }
        let machine = pressure == 4 ? "pause" : pressure == 2 || sustainedCPU ? "conserve" : snapshot.cpu == nil ? "unknown" : "continue"
        let accounts = Dictionary(uniqueKeysWithValues: providers.map { provider in
            (provider.id, ["recommendation": provider.recommendation,
                           "usedPercent": provider.limiting?.usedPercent as Any? ?? NSNull(),
                           "resetsAt": provider.limiting?.resetsAt as Any? ?? NSNull(),
                           "updatedAt": provider.record?.updatedAt as Any? ?? NSNull()] as [String: Any])
        })
        let data: [String: Any] = ["updatedAt": snapshot.date.timeIntervalSince1970, "staleAfterSeconds": 15,
                                  "advisoryOnly": true, "machine": machine,
                                  "memoryPressure": pressure, "cpuPercent": snapshot.cpu as Any? ?? NSNull(), "accounts": accounts]
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            let encoded = try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys])
            try encoded.write(to: Self.directory.appendingPathComponent("agent-status.json"), options: .atomic)
            writeError = nil
        } catch { writeError = "Agent status could not be saved." }
    }
}

func usageDial(_ used: Double?, color: NSColor) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 14, height: 14))
        ring.lineWidth = 2.3
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke(); ring.stroke()
        if let used {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 7, startAngle: 90, endAngle: 90 - CGFloat(used * 3.6), clockwise: true)
            arc.lineWidth = 2.3; arc.lineCapStyle = .round
            (used >= 80 ? NSColor.systemOrange : color).setStroke(); arc.stroke()
        } else {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(rect: NSRect(x: 6, y: 8, width: 6, height: 2)).fill()
        }
        return true
    }
    image.isTemplate = false
    return image
}

private let providerLogos: [String: NSImage] = Dictionary(uniqueKeysWithValues: ["codex", "claude"].compactMap { id in
    Bundle.main.url(forResource: id, withExtension: "png").flatMap { NSImage(contentsOf: $0) }.map { (id, $0) }
})

func providerDial(_ id: String, used: Double?) -> NSImage {
    let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
        let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 20, height: 20))
        ring.lineWidth = 1.8
        NSColor.secondaryLabelColor.withAlphaComponent(0.3).setStroke(); ring.stroke()
        if let used {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: 12, y: 12), radius: 10, startAngle: 90, endAngle: 90 - CGFloat(used * 3.6), clockwise: true)
            arc.lineWidth = 1.8; arc.lineCapStyle = .round
            (used >= 80 ? NSColor.systemOrange : .labelColor).setStroke(); arc.stroke()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 14, height: 14)).addClip()
        // Fill the circular crop so the original square app tile cannot show.
        providerLogos[id]?.draw(in: NSRect(x: 3, y: 3, width: 18, height: 18))
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    image.isTemplate = false
    return image
}
