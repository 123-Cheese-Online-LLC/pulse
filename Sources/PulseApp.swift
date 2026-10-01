import AppKit
import SwiftUI

@MainActor
final class PulsePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
    /// While hidden, the built SwiftUI view is detached (so it does no work) but kept for an instant reopen.
    private(set) var parked: NSView?
    override func orderOut(_ sender: Any?) { super.orderOut(sender); park() }
    func park() { if let view = contentView { parked = view; contentView = nil } }
    func unpark() { if let view = parked { contentView = view; parked = nil } }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PulsePanel!
    private let model = MonitorModel()
    private var captureStarted = false
    private var outsideClick: Any?
    private let hoverTracker = HoverTracker()
    private var hoverPanel: NSPanel!
    private var hoverWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["panelPinned": true])
        NSApplication.shared.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: 160)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: hoverTracker))
        }
        hoverPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        hoverPanel.level = .popUpMenu
        hoverPanel.isOpaque = false
        hoverPanel.backgroundColor = .clear
        hoverPanel.hasShadow = true
        hoverPanel.ignoresMouseEvents = true
        hoverPanel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        hoverTracker.onChange = { [weak self] inside in self?.hover(inside) }
        panel = PulsePanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        outsideClick = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if !UserDefaults.standard.bool(forKey: "panelPinned") { self?.panel.orderOut(nil) }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(displayChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        model.onUpdate = { [weak self] in
            self?.updateStatus()
            self?.captureIfReady()
        }
        updateStatus()
        model.start()
        // Pre-build the panel so the first click opens instantly too.
        if let button = statusItem.button, let window = button.window, let screen = window.screen ?? NSScreen.main {
            buildPanelContent(panelFrame(anchor: window.convertToScreen(button.convert(button.bounds, to: nil)), visibleFrame: screen.visibleFrame).size)
            panel.park()
        }
        if CommandLine.arguments.contains("--show") || CommandLine.arguments.contains("--capture") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePopover() }
        }
    }

    private func captureIfReady() {
        guard !captureStarted, model.cpuHistory.values.count >= 3 else { return }
        if let index = CommandLine.arguments.firstIndex(of: "--capture"), CommandLine.arguments.count > index + 1 {
            captureStarted = true
            let path = CommandLine.arguments[index + 1]
            // --detail captures the busiest quittable app's detail view instead of the list.
            if CommandLine.arguments.contains("--detail") {
                model.selectedAppID = model.snapshot?.apps.sorted { $0.cpu > $1.cpu }.first { model.canQuit($0) }?.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                guard let view = self.panel.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(2) }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(2) }
                do {
                    try data.write(to: URL(fileURLWithPath: path))
                    if let data = self.statusItem.button?.image?.tiffRepresentation,
                       let rep = NSBitmapImageRep(data: data),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: path + ".menubar.png"))
                    }
                    let providers = ["claude", "codex"].map { id in self.model.accountUsage.first { $0.id == id } ?? ProviderUsage(id: id, record: nil) }
                    let renderer = ImageRenderer(content: UsageHoverCard(providers: providers, machine: self.model.menuTitle))
                    renderer.scale = 2
                    if let hover = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: hover),
                       let png = rep.representation(using: .png, properties: [:]) {
                        try png.write(to: URL(fileURLWithPath: path + ".hover.png"))
                    }
                    let frame = self.panel.frame
                    let screen = self.panel.screen?.visibleFrame ?? .zero
                    let report = "window=\(frame)\nvisibleScreen=\(screen)\nfullyVisible=\(screen.contains(frame))\n"
                    try report.write(toFile: path + ".txt", atomically: true, encoding: .utf8)
                } catch { exit(2) }
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func updateStatus() {
        let providers = model.accountUsage.isEmpty ? [ProviderUsage(id: "codex", record: nil), ProviderUsage(id: "claude", record: nil)] : model.accountUsage
        let dials = ["claude", "codex"].map { id in
            providerDial(id, used: providers.first(where: { $0.id == id })?.limiting?.usedPercent)
        }
        let graph = menuGraph(isCPU: model.menuMetric == .cpu)
        let memoryGraph = menuGraph(isCPU: false)
        let title = model.menuTitle
        let labels = title.components(separatedBy: "  ")
        let both = model.menuReadout == "both"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let first = (labels.first ?? title) as NSString, second = (labels.last ?? "MEM —") as NSString
        // Lay the memory readout right after the CPU text instead of at a fixed x, so there's no gap.
        let memoryX = 95 + first.size(withAttributes: attributes).width + 8
        let width = ceil(both ? memoryX + 37 + second.size(withAttributes: attributes).width : 95 + first.size(withAttributes: attributes).width) + 2
        statusItem.length = width + 8
        let image = NSImage(size: NSSize(width: width, height: 24), flipped: false) { _ in
            dials[0].draw(in: NSRect(x: 0, y: 0, width: 24, height: 24))
            dials[1].draw(in: NSRect(x: 28, y: 0, width: 24, height: 24))
            graph.draw(in: NSRect(x: 58, y: 3, width: 32, height: 18))
            first.draw(at: NSPoint(x: 95, y: 5), withAttributes: attributes)
            if both {
                memoryGraph.draw(in: NSRect(x: memoryX, y: 3, width: 32, height: 18))
                second.draw(at: NSPoint(x: memoryX + 37, y: 5), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        statusItem.button?.title = ""
        statusItem.button?.image = image
        let summary = (["Pulse · " + title] + providers.map(\.summary)).joined(separator: "\n")
        // The hover card replaces the slow system tooltip; VoiceOver still gets the summary.
        statusItem.button?.setAccessibilityLabel(summary)
        if hoverPanel?.isVisible == true { showHoverCard() }
    }

    private func hover(_ inside: Bool) {
        hoverWork?.cancel()
        guard inside else { hoverPanel.orderOut(nil); return }
        // A short delay keeps the card from flashing when the pointer just passes over.
        let work = DispatchWorkItem { [weak self] in self?.showHoverCard() }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func showHoverCard() {
        guard !panel.isVisible, let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { hoverPanel.orderOut(nil); return }
        let providers = ["claude", "codex"].map { id in model.accountUsage.first { $0.id == id } ?? ProviderUsage(id: id, record: nil) }
        let hosting = NSHostingView(rootView: UsageHoverCard(providers: providers, machine: model.menuTitle))
        let size = hosting.fittingSize
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = screen.visibleFrame
        let x = min(max(anchor.minX, visible.minX + 8), visible.maxX - size.width - 8)
        hosting.frame = NSRect(origin: .zero, size: size)
        hoverPanel.contentView = hosting
        hoverPanel.setFrame(NSRect(x: x, y: anchor.minY - size.height - 6, width: size.width, height: size.height), display: true)
        hoverPanel.orderFront(nil)
    }

    private func menuGraph(isCPU: Bool) -> NSImage {
        let values = Array((isCPU ? model.cpuHistory.values : model.memoryHistory.values).suffix(20))
        let image = NSImage(size: NSSize(width: 38, height: 18), flipped: false) { rect in
            guard let last = values.last else {
                NSColor.secondaryLabelColor.setFill()
                NSBezierPath(roundedRect: NSRect(x: 2, y: 8, width: 34, height: 2), xRadius: 1, yRadius: 1).fill()
                return true
            }
            let color: NSColor = isCPU ? (last >= 85 ? .systemOrange : .systemTeal) : .systemBlue
            let line = NSBezierPath()
            let points = values.enumerated().map { index, value in
                NSPoint(x: 2 + 34 * Double(index) / Double(max(1, values.count - 1)), y: 2 + 14 * min(100, max(0, value)) / 100)
            }
            line.move(to: points[0])
            for point in points.dropFirst() { line.line(to: point) }
            let area = line.copy() as! NSBezierPath
            area.line(to: NSPoint(x: points.last!.x, y: 1))
            area.line(to: NSPoint(x: points[0].x, y: 1)); area.close()
            color.withAlphaComponent(0.18).setFill(); area.fill()
            color.setStroke(); line.lineWidth = 1.6; line.lineJoinStyle = .round; line.stroke()
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: points.last!.x - 1.5, y: points.last!.y - 1.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc func togglePopover() {
        hoverWork?.cancel()
        hoverPanel.orderOut(nil)
        if panel.isVisible { panel.orderOut(nil); return }
        showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, let window = button.window,
              let screen = window.screen ?? NSScreen.main else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let frame = panelFrame(anchor: anchor, visibleFrame: screen.visibleFrame)
        // Built once and reused so clicks open instantly; rebuilt only if the display size changes.
        panel.unpark()
        if panel.contentView == nil || panel.frame.size != frame.size { buildPanelContent(frame.size) }
        panel.setFrame(frame, display: true)
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func buildPanelContent(_ size: CGSize) {
        let hosting = NSHostingView(rootView: PopoverView(model: model, panelSize: size))
        hosting.sizingOptions = []
        panel.contentView = hosting
        panel.setContentSize(size)
    }

    @objc private func displayChanged() {
        if panel.isVisible { showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }
}

@main
struct PulseMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            let sampler = Sampler()
            _ = sampler.sample()
            Thread.sleep(forTimeInterval: 3)
            let result = sampler.sample()
            let data: [String: Any] = [
                "cpu": result.cpu as Any? ?? NSNull(),
                "memoryUsed": result.memoryUsed as Any? ?? NSNull(),
                "memoryTotal": result.memoryTotal,
                "pressure": result.pressure,
                "swapUsed": result.swapUsed as Any? ?? NSNull(),
                "groups": result.apps.count,
                "processes": result.apps.reduce(0) { $0 + $1.pids.count },
                "skipped": result.skipped,
                "processError": result.processError,
                "topCPU": result.apps.sorted { $0.cpu > $1.cpu }.prefix(6).map { ["name": $0.name, "cpu": $0.cpu, "memory": $0.memory] as [String: Any] }
            ]
            if let json = try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]), let text = String(data: json, encoding: .utf8) { print(text) }
            exit(result.cpu != nil && result.memoryUsed != nil && !result.apps.isEmpty ? 0 : 1)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
