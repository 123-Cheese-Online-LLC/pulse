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
    // Pin/unpin bounce for menu bar dials: ids animating in or out, with their start time.
    private var shownDials: [String] = []
    private var dialMotion: [String: (start: Date, appearing: Bool)] = [:]
    private var dialTimer: Timer?
    private var drewDials = false
    private var statusWidth: CGFloat = 0
    // Notch fit: when macOS hides Pulse for lack of menu bar room, drop the graphs and the second readout.
    private var compactMenu = false
    private var lastFrontApp: String?
    private var compactSince = Date.distantPast
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
            // --detail [name]: capture that app's detail card (default: the busiest quittable app).
            if let flag = CommandLine.arguments.firstIndex(of: "--detail") {
                let name = CommandLine.arguments.dropFirst(flag + 1).first.flatMap { $0.hasPrefix("-") ? nil : $0 }
                let apps = model.snapshot?.apps.sorted { $0.cpu > $1.cpu } ?? []
                model.selectedAppID = (name.flatMap { n in apps.first { $0.name == n } } ?? apps.first { model.canQuit($0) })?.id
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
                    let providers = self.model.accountUsage
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

    /// frameOnly: an animation frame. Redraw the image and nothing else (no hover card, no accessibility text).
    func updateStatus(frameOnly: Bool = false) {
        if !frameOnly { fitMenuBar() }
        let providers = model.accountUsage
        // Pinned tools (max 3) become dials; everything after them shifts to fit.
        let pinned = Array(model.pinned.prefix(3))
        trackPinChanges(pinned)
        let slots = shownDials.map { id in (id: id, scale: dialScale(id)) }
        let dials = slots.map { slot in
            (image: providerDial(slot.id, used: providers.first(where: { $0.id == slot.id })?.limiting?.usedPercent), scale: slot.scale)
        }
        // A dial's slot grows and shrinks with it, so neighbours slide rather than jump.
        let dialsWidth = dials.reduce(CGFloat(0)) { $0 + 28 * min(1, $1.scale) }
        let start = dialsWidth + (dialsWidth > 0.5 ? 2 : 0)
        let graph = menuGraph(isCPU: model.menuMetric == .cpu)
        let memoryGraph = menuGraph(isCPU: false)
        let title = model.menuTitle
        let labels = title.components(separatedBy: "  ")
        let both = model.menuReadout == "both" && !compactMenu
        let graphGap: CGFloat = compactMenu ? 0 : 37 // compact: no graph, just the readout
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor]
        let first = (labels.first ?? title) as NSString, second = (labels.last ?? "MEM —") as NSString
        // Lay the memory readout right after the CPU text instead of at a fixed x, so there's no gap.
        let memoryX = start + graphGap + first.size(withAttributes: attributes).width + 8
        let width = ceil(both ? memoryX + 37 + second.size(withAttributes: attributes).width : start + graphGap + first.size(withAttributes: attributes).width) + 2
        // While dials move, keep the item at its widest so the menu bar never re-lays out mid-animation;
        // content is right-aligned in that space, so the CPU readout stays put and only the dial moves.
        let fullWidth = width + CGFloat(shownDials.count) * 28 - dialsWidth + (dialsWidth > 0.5 || shownDials.isEmpty ? 0 : 2)
        let itemWidth = dialMotion.isEmpty ? width : max(width, ceil(fullWidth), statusWidth)
        if itemWidth != statusWidth { statusItem.length = itemWidth + 8; statusWidth = itemWidth }
        let offset = itemWidth - width
        let image = NSImage(size: NSSize(width: itemWidth, height: 24), flipped: false) { _ in
            NSGraphicsContext.current?.cgContext.translateBy(x: offset, y: 0)
            var x: CGFloat = 0
            for dial in dials {
                let size = 24 * dial.scale
                if size > 0.5 { dial.image.draw(in: NSRect(x: x + 12 * min(1, dial.scale) - size / 2, y: 12 - size / 2, width: size, height: size)) }
                x += 28 * min(1, dial.scale)
            }
            if !self.compactMenu { graph.draw(in: NSRect(x: start, y: 3, width: 32, height: 18)) }
            first.draw(at: NSPoint(x: start + graphGap, y: 5), withAttributes: attributes)
            if both {
                memoryGraph.draw(in: NSRect(x: memoryX, y: 3, width: 32, height: 18))
                second.draw(at: NSPoint(x: memoryX + 37, y: 5), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = false
        statusItem.button?.title = ""
        statusItem.button?.image = image
        if frameOnly { return }
        let summary = (["Pulse · " + title] + providers.map(\.summary)).joined(separator: "\n")
        // The hover card replaces the slow system tooltip; VoiceOver still gets the summary.
        statusItem.button?.setAccessibilityLabel(summary)
        if hoverPanel?.isVisible == true { showHoverCard() }
    }

    /// macOS hides menu bar items that don't fit beside the notch (busy app menus, a screen-share
    /// indicator…). If that happens, go compact; when the menu bar changes, try full size again.
    private func fitMenuBar() {
        guard let window = statusItem.button?.window else { return }
        let hidden = !window.occlusionState.contains(.visible)
            || (window.screen?.auxiliaryTopRightArea).map { window.frame.minX < $0.minX - 1 } == true
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        defer { lastFrontApp = front }
        if hidden && !compactMenu {
            compactMenu = true
            compactSince = Date()
        } else if !hidden && compactMenu && (front != lastFrontApp || Date().timeIntervalSince(compactSince) > 60) {
            compactSince = Date()
            compactMenu = false
            // Check the full size actually fits; if not, back to compact without waiting for the next sample.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.updateStatus() }
        }
    }

    /// Starts an in/out bounce for any dial whose pin changed, and keeps leaving dials drawn until they're gone.
    private func trackPinChanges(_ pinned: [String]) {
        let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let added = pinned.filter { !shownDials.contains($0) }
        let removed = shownDials.filter { !pinned.contains($0) && dialMotion[$0]?.appearing != false }
        if !drewDials { drewDials = true; shownDials = pinned; return } // first draw at launch: no bounce
        for id in added { dialMotion[id] = still ? nil : (Date(), true) }
        // Re-pinned while still leaving: turn around and bounce back in.
        for id in pinned where dialMotion[id]?.appearing == false { dialMotion[id] = (Date(), true) }
        for id in removed { if still { shownDials.removeAll { $0 == id } } else { dialMotion[id] = (Date(), false) } }
        // Keep pinned order, with leaving dials staying where they were.
        var order = shownDials.filter { pinned.contains($0) || dialMotion[$0]?.appearing == false }
        for id in pinned where !order.contains(id) { order.insert(id, at: min(pinned.firstIndex(of: id) ?? order.count, order.count)) }
        shownDials = order
        if !dialMotion.isEmpty && dialTimer == nil {
            // Redraw only while something is moving (~0.4 s), then stop.
            dialTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateStatus(frameOnly: true) }
            }
        }
    }

    /// Back-easing: in overshoots to ~1.1 then settles; out pops a touch then shrinks to nothing.
    private func dialScale(_ id: String) -> CGFloat {
        guard let motion = dialMotion[id] else { return 1 }
        let duration = motion.appearing ? 0.45 : 0.30
        let t = min(1, Date().timeIntervalSince(motion.start) / duration)
        let c1 = 1.7, c3 = c1 + 1
        let scale = motion.appearing ? 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2) : 1 - (c3 * t * t * t - c1 * t * t)
        if t >= 1 {
            dialMotion[id] = nil
            if !motion.appearing { shownDials.removeAll { $0 == id } }
            if dialMotion.isEmpty {
                dialTimer?.invalidate(); dialTimer = nil
                DispatchQueue.main.async { [weak self] in self?.updateStatus() } // settle to the final width once
            }
            return motion.appearing ? 1 : 0
        }
        return max(0, CGFloat(scale))
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
        let providers = model.accountUsage
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
        model.panelOpens += 1
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
