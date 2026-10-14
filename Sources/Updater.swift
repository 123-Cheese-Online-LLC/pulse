import AppKit
import UserNotifications

/// Checks GitHub about once a day for a newer Pulse and, when asked, rebuilds it on this Mac the same
/// way the installer does (a locally built app isn't blocked by Gatekeeper), then restarts it.
final class Updater: ObservableObject {
    enum State: Equatable { case idle, upToDate, available(String), updating, failed(String) }
    static let shared = Updater()
    static let repo = "123-Cheese-Online-LLC/pulse"
    @Published private(set) var state: State = .idle
    /// The commit this copy was built from; builds older than the updater don't have one.
    let current = Bundle.main.object(forInfoDictionaryKey: "PulseCommit") as? String ?? ""
    private var lastCheck = Date.distantPast
    private var process: Process?

    func checkIfDue() {
        guard Date().timeIntervalSince(lastCheck) > 86_400, state != .updating else { return }
        check()
    }

    /// Asks GitHub what changed since this build. Only changes to the app itself count, not docs or tests.
    func check(manual: Bool = false) {
        lastCheck = Date()
        guard current.count == 40, let url = URL(string: "https://api.github.com/repos/\(Self.repo)/compare/\(current)...main") else {
            if manual { state = .failed("This copy can't update itself. Reinstall it once with the installer.") }
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let files = (json?["files"] as? [[String: Any]] ?? []).compactMap { $0["filename"] as? String }
            let latest = (json?["commits"] as? [[String: Any]])?.last?["sha"] as? String
            let matters = files.contains { ["Sources/", "Integrations/", "Resources/", "scripts/build.sh"].contains(where: $0.hasPrefix) }
            DispatchQueue.main.async {
                guard self.state != .updating else { return }
                if (response as? HTTPURLResponse)?.statusCode != 200 {
                    // 404 means this build's commit was never pushed (a local build), which isn't an error for anyone else.
                    if manual { self.state = .failed("Couldn't reach GitHub. Try again later.") }
                } else if json?["status"] as? String == "ahead", matters, let latest, latest.count == 40 {
                    self.state = .available(latest)
                    self.notifyOnce(latest)
                } else if manual {
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    /// Runs the bundled update script: download that commit, build it, then quit, swap and relaunch Pulse.
    func install() {
        guard case .available(let sha) = state, process?.isRunning != true,
              let script = Bundle.main.url(forResource: "update", withExtension: "sh") else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path, sha, Bundle.main.bundlePath, String(getpid())]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.terminationHandler = { task in
            // On success the script quits Pulse before it exits, so this only runs on failure.
            DispatchQueue.main.async {
                self.state = .failed(task.terminationStatus == 3
                    ? "Updating needs Apple's Command Line Tools. Install them from the window that opened, then try again."
                    : "The update didn't finish. Pulse is unchanged. Details are in update.log.")
            }
        }
        do { try task.run(); process = task; state = .updating }
        catch { state = .failed("The update couldn't start.") }
    }

    func dismiss() {
        switch state { case .upToDate, .failed: state = .idle; default: break }
    }

    /// One notification per new version, so someone who never opens the panel still hears about it.
    private func notifyOnce(_ sha: String) {
        guard UserDefaults.standard.string(forKey: "notifiedUpdate") != sha else { return }
        UserDefaults.standard.set(sha, forKey: "notifiedUpdate")
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Pulse update available"
            content.body = "Click Pulse in the menu bar, then Update."
            center.add(UNNotificationRequest(identifier: "pulse-update", content: content, trigger: nil))
        }
    }
}
