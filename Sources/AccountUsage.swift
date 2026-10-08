import Foundation
import AppKit

struct UsageWindow: Codable {
    let label: String
    let usedPercent: Double
    let resetsAt: Double
    var estimated: Bool? = nil // From local token counts and a learned tokens-per-percent, not an exact reading.
}
struct UsageRecord: Codable {
    let updatedAt: Double
    let windows: [UsageWindow]
    var note: String? = nil // Why there is no exact reading, e.g. no Claude Code login.
    var local: LocalTokens? = nil // Fallback when no % is available.
    var spend: Spend? = nil // API providers report dollars instead of a %.
}
struct Spend: Codable {
    let usd: Double
    let label: String
}
/// Every provider the bridge can read, in display order. Claude and Codex always show.
let providerOrder = ["claude", "codex", "gemini", "copilot", "openai-api", "anthropic-api"]
let providerNames = ["claude": "Claude", "codex": "Codex", "gemini": "Gemini", "copilot": "Copilot",
                     "openai-api": "OpenAI API", "anthropic-api": "Anthropic API"]
struct LocalTokens: Codable {
    let fiveHourTokens: Int
    let weekTokens: Int
    var windowTokens: Int? = nil    // tokens in Claude's open 5-hour window
    var windowResetsAt: Double? = nil
    var text: String {
        guard let windowTokens, let windowResetsAt else { return "\(compactTokens(weekTokens)) tokens this week" }
        let reset = Date(timeIntervalSince1970: windowResetsAt).formatted(date: .omitted, time: .shortened)
        return "\(compactTokens(windowTokens)) tokens this window · resets \(reset)"
    }
}
func compactTokens(_ n: Int) -> String {
    n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1_000_000) : n >= 1_000 ? "\(n / 1_000)K" : "\(n)"
}
struct ProviderUsage: Identifiable {
    let id: String
    let record: UsageRecord?
    var name: String { providerNames[id] ?? id }
    /// Readings older than 15 minutes are never shown as current.
    private var fresh: UsageRecord? {
        let now = Date().timeIntervalSince1970
        guard let record, now - record.updatedAt < 900, record.updatedAt <= now + 60 else { return nil }
        return record
    }
    var activeWindows: [UsageWindow] {
        let now = Date().timeIntervalSince1970
        return (fresh?.windows ?? []).filter { $0.usedPercent.isFinite && (0...100).contains($0.usedPercent) && $0.resetsAt > now }
    }
    var localTokens: LocalTokens? { fresh?.local }
    var spend: Spend? { fresh?.spend }
    /// Short tile value: %, then $, then tokens.
    var valueText: String {
        if let limiting { return "\(limiting.estimated == true ? "~" : "")\(Int(limiting.usedPercent))%" }
        if let spend { return String(format: "$%.2f", spend.usd) }
        if let localTokens { return compactTokens(localTokens.windowTokens ?? localTokens.weekTokens) }
        return "—"
    }
    /// Which limit the tile's % refers to, e.g. "5h" or "week".
    var valueCaption: String? {
        guard let label = limiting?.label else { return spend != nil ? "month" : localTokens == nil ? nil : localTokens?.windowTokens != nil ? "tok" : "tok/wk" }
        return ["5 hour": "5h", "Weekly": "week", "Weekly Opus": "Opus wk", "Weekly Sonnet": "Sonnet wk"][label] ?? label.lowercased()
    }
    /// One-line reading when there's no % to show.
    var detailText: String? {
        if let spend { return String(format: "$%.2f · %@", spend.usd, spend.label.lowercased()) }
        if let localTokens { return localTokens.text }
        return record?.note
    }
    var limiting: UsageWindow? { activeWindows.max { $0.usedPercent < $1.usedPercent } }
    var recommendation: String {
        guard let used = limiting?.usedPercent else { return "unknown" }
        return used >= 95 ? "pause" : used >= 80 ? "conserve" : "continue"
    }
    var summary: String {
        guard let window = limiting else {
            return "\(name): " + (detailText ?? "no current reading")
        }
        let reset = Date(timeIntervalSince1970: window.resetsAt).formatted(date: .abbreviated, time: .shortened)
        return "\(name): \(window.estimated == true ? "~" : "")\(Int(window.usedPercent))% used\(window.estimated == true ? " (est.)" : "") · \(window.label) · resets \(reset) · \(recommendation)"
    }
}

final class AccountUsage {
    static var directory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Pulse") }
    private var process: Process?
    private var lastRefresh = Date.distantPast
    private var fastUntil = Date.distantPast // After Connect, poll every 30s for 5 min to pick up the new login.
    var writeError: String?

    func read() -> [ProviderUsage] {
        providerOrder.compactMap { name in
            let url = Self.directory.appendingPathComponent("\(name)-usage.json")
            let record = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(UsageRecord.self, from: $0) }
            // Providers that aren't set up have no file and no tile.
            return record != nil || name == "claude" || name == "codex" ? ProviderUsage(id: name, record: record) : nil
        }
    }
    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefresh) >= (Date() < fastUntil ? 30 : 300), process?.isRunning != true,
              let script = Bundle.main.url(forResource: "usage_bridge", withExtension: "py") else { return }
        lastRefresh = Date()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [script.path, "refresh"] // Every provider
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); process = task } catch { process = nil }
    }
    /// Opens Terminal to sign Claude Code in; Pulse reads exact limits once that login exists.
    func connectClaude() {
        let script = Self.directory.appendingPathComponent("connect-claude.command")
        let bridge = Bundle.main.url(forResource: "usage_bridge", withExtension: "py")?.path ?? ""
        // Several copies of `claude` can be installed and old ones may crash; use the newest that runs.
        let body = """
        #!/bin/zsh -l
        best=""; bestv=""
        for c in $(whence -ap claude) ~/.nvm/versions/node/*/bin/claude(N) ~/.local/bin/claude(N) /opt/homebrew/bin/claude(N); do
          v=$("$c" --version 2>/dev/null | awk '{print $1}') || continue
          [[ -n "$v" && "$(printf '%s\\n%s\\n' "$bestv" "$v" | sort -V | tail -1)" == "$v" ]] && { best=$c; bestv=$v; }
        done
        [[ -n "$best" ]] || { echo "Claude Code isn't installed. Get it at https://claude.com/claude-code"; exit 1; }
        # Versions before 2.0 have no `auth login` and would open a chat instead of signing in.
        if (( ${bestv%%.*} < 2 )); then
          echo "Claude Code $bestv is too old to sign in from here. Update it, then click Connect again:"
          echo "  npm install -g @anthropic-ai/claude-code"
          exit 1
        fi
        echo "using Claude Code $bestv"
        if "$best" auth login; then
          # Refresh right away so the exact limits appear within seconds, not at the next 5-minute check.
          /usr/bin/python3 "\(bridge)" claude-api >/dev/null 2>&1
          echo "\nDone. Pulse now shows your exact Claude limits. You can close this window."
        fi
        """
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        guard (try? body.write(to: script, atomically: true, encoding: .utf8)) != nil,
              (try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)) != nil else { return }
        NSWorkspace.shared.open(script) // .command files open in Terminal without extra permissions.
        fastUntil = Date().addingTimeInterval(300)
        lastRefresh = .distantPast
    }
    /// Whether an admin key is saved for this provider (checks the Keychain entry exists; never reads the key).
    func hasKey(_ provider: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", "Pulse: \(provider)-admin-key"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
    /// Saves (or, when empty, removes) an admin API key in the Keychain for the bridge to read.
    /// The key goes to `security` on stdin, never on a command line, and is limited to key characters.
    func saveKey(_ provider: String, key: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines), service = "Pulse: \(provider)-admin-key"
        guard key.isEmpty || key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return false }
        let task = Process(), input = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["-i"]
        task.standardInput = input
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        let command = key.isEmpty ? "delete-generic-password -s \"\(service)\"\n"
            : "add-generic-password -U -a pulse -s \"\(service)\" -w \"\(key)\"\n"
        input.fileHandleForWriting.write(command.data(using: .utf8)!)
        input.fileHandleForWriting.closeFile()
        task.waitUntilExit()
        fastUntil = Date().addingTimeInterval(120); lastRefresh = .distantPast
        return true
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

/// API spend tiles reuse the company logo of the matching assistant.
private let providerLogoID = ["openai-api": "codex", "anthropic-api": "claude"]
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
        if let logo = providerLogos[providerLogoID[id] ?? id] {
            logo.draw(in: NSRect(x: 3, y: 3, width: 18, height: 18))
        } else {
            // Tools without a bundled logo get a monochrome initial.
            let letter = (providerNames[id] ?? id).prefix(1) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .bold), .foregroundColor: NSColor.labelColor]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: 12 - size.width / 2, y: 12 - size.height / 2), withAttributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        return true
    }
    image.isTemplate = false
    return image
}
