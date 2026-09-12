import AppKit
import SwiftUI
import ApplicationServices

@MainActor final class WidgetHost: NSHostingView<WidgetFace> {
    var clicked: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { clicked?() }
}

@MainActor final class DockOverlays {
    private var panels: [UUID: NSPanel] = [:]
    private var groups: [WidgetPlacement] = []
    private var timer: Timer?
    private let telemetry: Telemetry
    private let timers: WidgetTimers
    private let clicked: (WidgetInstance) -> Void
    var allVisible: Bool { groups.allSatisfy { panels[$0.widget.id]?.isVisible == true } }
    init(telemetry: Telemetry, timers: WidgetTimers, clicked: @escaping (WidgetInstance) -> Void) {
        self.telemetry = telemetry; self.timers = timers; self.clicked = clicked
        timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.position() } }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func update(_ groups: [WidgetPlacement]) {
        for panel in panels.values { panel.orderOut(nil); panel.close() }
        panels = [:]; self.groups = groups
        for group in groups {
            let widget = group.widget
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 76, height: 33), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.title = "Dock Studio · \(widget.kind.title)"
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let host = WidgetHost(rootView: WidgetFace(widget: widget, telemetry: telemetry, timers: timers))
            host.clicked = { [weak self] in self?.clicked(widget) }
            host.toolTip = widget.kind.isTimer ? "Click to start or pause \(widget.kind.title.lowercased())" : "Open \(widget.kind.title) in Dock Studio"
            panel.contentView = host; panels[widget.id] = panel
        }
        position()
    }
    func hide() { panels.values.forEach { $0.orderOut(nil) } }
    func stop() { timer?.invalidate(); hide(); panels.values.forEach { $0.close() }; panels = [:] }
    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?; AXUIElementCopyAttributeValue(element, name as CFString, &value); return value
    }
    private func frame(_ element: AXUIElement) -> CGRect? {
        guard let p = attribute(element, "AXPosition"), let s = attribute(element, "AXSize"), CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }
    private func position() {
        guard !groups.isEmpty, AXIsProcessTrusted(), let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { hide(); return }
        guard (UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom") == "bottom" else { hide(); return }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = (attribute(root, "AXChildren") as? [AXUIElement])?.first,
              let items = attribute(list, "AXChildren") as? [AXUIElement] else { hide(); return }
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        for group in groups {
            guard let panel = panels[group.widget.id] else { continue }
            let start = group.index + 1
            guard start >= 1, items.count >= start + group.widget.units else { panel.orderOut(nil); continue }
            let tiles = Array(items[start..<(start + group.widget.units)])
            guard tiles.allSatisfy({ attribute($0, "AXSubrole") as? String == "AXSpacerDockItem" }) else { panel.orderOut(nil); continue }
            let rects = tiles.compactMap(frame)
            guard rects.count == group.widget.units, let first = rects.first, let unit = rects.map(\.width).min(), unit > 20,
                  rects.allSatisfy({ abs($0.minY - first.minY) < 40 }) else { panel.orderOut(nil); continue }
            let union = rects.dropFirst().reduce(first) { $0.union($1) }
            let height = ((unit - 2) * 0.8).rounded()
            let inset = (unit - height) / 2
            let topInset = (unit - 2 - height) / 2 + 7
            let target = CGRect(x: union.minX + inset, y: desktopTop - union.minY - height - topInset, width: union.width - 2 * inset, height: height)
            guard NSScreen.screens.contains(where: { $0.frame.contains(CGPoint(x: target.midX, y: target.midY)) }) else { panel.orderOut(nil); continue }
            if panel.frame != target { panel.setFrame(target, display: true) }
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
    }
}
