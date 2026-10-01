import Foundation
@main struct AccountUsageTests {
    static func main() {
        let now = Date().timeIntervalSince1970
        func provider(_ used: [Double], age: Double = 0, reset: Double = 3600) -> ProviderUsage {
            ProviderUsage(id: "codex", record: UsageRecord(updatedAt: now-age, windows: used.map { UsageWindow(label: "Test", usedPercent: $0, resetsAt: now+reset) }))
        }
        precondition(provider([0, 96]).recommendation == "pause", "Most constrained window must govern")
        precondition(provider([80]).recommendation == "conserve")
        precondition(provider([20]).recommendation == "continue")
        precondition(provider([0], age: 901).recommendation == "unknown", "Stale is not zero")
        precondition(provider([90], reset: -1).limiting == nil)
        precondition(provider([1000000, -1, .nan]).limiting == nil)
        precondition(ProviderUsage(id: "claude", record: nil).recommendation == "unknown")
        print("7 account usage checks passed")
    }
}
