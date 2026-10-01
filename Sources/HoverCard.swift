import AppKit
import SwiftUI

/// Quick glance at account limits while the pointer rests on the menu bar item.
struct UsageHoverCard: View {
    let providers: [ProviderUsage]
    let machine: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(providers) { provider in
                VStack(alignment: .leading, spacing: 5) {
                    Text(provider.name).font(.system(size: 11, weight: .semibold))
                    if provider.activeWindows.isEmpty {
                        // Spend or token counts when there's no %; unknown is never shown as 0%.
                        Text(provider.detailText ?? "No current reading").font(.system(size: 10)).monospacedDigit()
                            .foregroundStyle(provider.spend == nil && provider.localTokens == nil ? .secondary : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(provider.activeWindows, id: \.label) { window in row(window) }
                }
            }
            Divider()
            Text(machine).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }

    private func row(_ window: UsageWindow) -> some View {
        let used = window.usedPercent
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.system(size: 10))
                Spacer()
                Text("\(Int(used.rounded()))%").font(.system(size: 10, weight: .medium)).monospacedDigit()
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(used >= 80 ? Color.orange : Color.primary.opacity(0.7))
                        .frame(width: geometry.size.width * used / 100)
                }
            }.frame(height: 4)
            Text("Resets " + resetText(window.resetsAt)).font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func resetText(_ time: Double) -> String {
        let date = Date(timeIntervalSince1970: time)
        // Today: time only. This week: weekday + time. Further out: the date, so "Sat" isn't misread.
        if Calendar.current.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        return date.timeIntervalSinceNow < 6 * 86400 ? date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Receives enter/exit events for the status item button.
final class HoverTracker: NSResponder {
    var onChange: (Bool) -> Void = { _ in }
    override func mouseEntered(with event: NSEvent) { onChange(true) }
    override func mouseExited(with event: NSEvent) { onChange(false) }
}
