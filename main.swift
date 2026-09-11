import AppKit
import ApplicationServices
import Darwin

let domain = "com.apple.dock" as CFString
let placement = UserDefaults(suiteName: "local.dock-2u")!
func slotIndex(in entries: [[String: Any]]) -> Int? {
    let indices = entries.indices.filter { entries[$0]["tile-type"] as? String == "spacer-tile" }
    guard indices.count == 2, indices[1] == indices[0] + 1 else { return nil }
    return indices[0]
}
func tiles() -> [[String: Any]] {
    CFPreferencesAppSynchronize(domain)
    return CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] ?? []
}
func setTiles(_ value: [[String: Any]]) {
    CFPreferencesSetAppValue("persistent-apps" as CFString, value as CFArray, domain)
    CFPreferencesAppSynchronize(domain)
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); task.arguments = ["Dock"]
    try? task.run(); task.waitUntilExit()
}
func removeSlots() {
    let old = tiles()
    // macOS strips spacer GUIDs. This prototype requires its pair to be the
    // only full-size spacers and refuses ambiguous layouts rather than deleting.
    guard let index = slotIndex(in: old) else { return }
    var clean = old; clean.removeSubrange(index..<(index + 2))
    setTiles(clean)
}
if CommandLine.arguments.contains("--cleanup") { removeSlots(); exit(0) }
guard !tiles().contains(where: { $0["tile-type"] as? String == "spacer-tile" }) else { fputs("Full-size spacers already exist; quit the running experiment before relaunching.\n", stderr); exit(1) }
guard AXIsProcessTrusted() else { fputs("Accessibility permission is required for Dock tracking.\n", stderr); exit(1) }

func attr(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?; AXUIElementCopyAttributeValue(element, name as CFString, &value); return value
}
func rect(_ element: AXUIElement) -> CGRect? {
    guard let p = attr(element, "AXPosition"), let s = attr(element, "AXSize"),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point); AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

final class Graph: NSView {
    var cpu: [Double] = [], memory: [Double] = []
    var onDragStart: (() -> Void)?
    var onDragEnd: ((CGPoint) -> Void)?
    var dragOffset: CGPoint?
    var didDrag = false
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = NSEvent.mouseLocation
        dragOffset = CGPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        didDrag = false; onDragStart?(); NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let offset = dragOffset else { return }
        didDrag = true
        let point = NSEvent.mouseLocation
        window?.setFrameOrigin(CGPoint(x: point.x - offset.x, y: point.y - offset.y))
    }
    override func mouseUp(with event: NSEvent) {
        guard dragOffset != nil else { return }
        dragOffset = nil; NSCursor.pop()
        onDragEnd?(didDrag ? NSEvent.mouseLocation : CGPoint(x: CGFloat.nan, y: CGFloat.nan))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.075, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let colors = [NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.75, green: 0.64, blue: 1, alpha: 1)]
        for (i, data) in [cpu, memory].enumerated() {
            let scale = bounds.height / 33
            let padding = 5 * scale
            let row = (bounds.height - 6 * scale) / 2
            let y = bounds.height - 3 * scale - CGFloat(i + 1) * row
            let font = NSFont(name: "Helvetica Neue", size: 8 * scale)!
            let value = data.last ?? 0
            let label = "\(i == 0 ? "CPU" : "Mem") \(Int(value * 100))%" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colors[i]]
            let textHeight = label.size(withAttributes: attributes).height
            label.draw(at: CGPoint(x: padding, y: y + (row - textHeight) / 2), withAttributes: attributes)
            let graphX = 50 * scale
            let graph = CGRect(x: graphX, y: y + (row - 8 * scale) / 2, width: max(4, bounds.width - graphX - padding), height: 8 * scale)
            let path = NSBezierPath(); path.lineWidth = 1.2
            for (j, v) in data.enumerated() {
                let p = CGPoint(x: graph.maxX - CGFloat(data.count - 1 - j) * graph.width / 59, y: graph.minY + CGFloat(v) * graph.height)
                if j == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            colors[i].setStroke(); path.stroke()
        }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var graph = Graph()
    var status: NSStatusItem!
    var timer: Timer?, tracking: Timer?
    var lastTicks: [UInt32]?
    var sampleCount = 0
    var dragging = false
    var currentIndex = 0
    var dragEntries: [[String: Any]] = []
    var dropCenters: [CGFloat] = []
    var dockBand = CGRect.zero
    func dockItems() -> [AXUIElement] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = (attr(root, "AXChildren") as? [AXUIElement])?.first else { return [] }
        return attr(list, "AXChildren") as? [AXUIElement] ?? []
    }
    func beginDrag() {
        dragEntries = tiles(); dropCenters = []
        guard let index = slotIndex(in: dragEntries) else { return }
        currentIndex = index
        let items = dockItems()
        guard items.count > dragEntries.count else { return }
        for i in dragEntries.indices where i != index && i != index + 1 {
            guard let frame = rect(items[i + 1]) else { return }
            dropCenters.append(frame.midX)
        }
        dockBand = panel.frame.insetBy(dx: 0, dy: -45)
        dragging = true
    }
    func endDrag(at point: CGPoint) {
        defer { dragging = false; position() }
        guard dragging, point.x.isFinite, point.y >= dockBand.minY, point.y <= dockBand.maxY,
              NSArray(array: tiles()).isEqual(to: dragEntries), let oldIndex = slotIndex(in: dragEntries) else { return }
        let destination = dropCenters.filter { $0 < point.x }.count
        guard destination != oldIndex else { return }
        var updated = dragEntries
        let pair = Array(updated[oldIndex..<(oldIndex + 2)])
        updated.removeSubrange(oldIndex..<(oldIndex + 2))
        updated.insert(contentsOf: pair, at: destination)
        currentIndex = destination
        placement.set(destination, forKey: "insertionIndex")
        panel.orderOut(nil)
        setTiles(updated)
        print("Moved widget from slot \(oldIndex) to \(destination)"); fflush(stdout)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let existing = tiles()
        let backup = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dock-2u-before.plist")
        if !FileManager.default.fileExists(atPath: backup.path), let data = try? PropertyListSerialization.data(fromPropertyList: existing, format: .xml, options: 0) { try? data.write(to: backup) }
        currentIndex = min(existing.count, max(0, placement.integer(forKey: "insertionIndex")))
        var updated = existing
        updated.insert(contentsOf: (0..<2).map { _ in ["tile-type": "spacer-tile", "tile-data": [:]] as [String: Any] }, at: currentIndex)
        setTiles(updated)
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 86, height: 41), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Dock 2U CPU and memory"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = false
        panel.contentView = graph
        graph.onDragStart = { [weak self] in self?.beginDrag() }
        graph.onDragEnd = { [weak self] point in self?.endDrag(at: point) }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.title = "2U"
        let menu = NSMenu(); let quit = menu.addItem(withTitle: "Quit and remove test slots", action: #selector(quitApp), keyEquivalent: "q"); quit.target = self; status.menu = menu
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        tracking = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.position() }
    }
    @objc func quitApp() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); tracking?.invalidate(); panel.orderOut(nil); removeSlots() }
    func position() {
        guard !dragging else { return }
        let items = dockItems()
        let first = currentIndex + 1
        guard items.count > first + 1,
              attr(items[first], "AXSubrole") as? String == "AXSpacerDockItem",
              attr(items[first + 1], "AXSubrole") as? String == "AXSpacerDockItem",
              let a = rect(items[first]), let b = rect(items[first + 1]), a.width > 20, b.width > 20,
              abs(a.minY - b.minY) < 30 else { panel.orderOut(nil); return }
        let union = a.union(b)
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let tileHeight = min(a.width, b.width) - 2
        let height = (tileHeight * 0.8).rounded()
        let topInset = (tileHeight - height) / 2 + 7
        let sideInset = (min(a.width, b.width) - height) / 2
        let frame = CGRect(x: union.minX + sideInset, y: desktopTop - union.minY - height - topInset, width: union.width - 2 * sideInset, height: height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }), frame.minY >= 0 else { panel.orderOut(nil); return }
        panel.setFrame(frame, display: true); panel.orderFrontRegardless()
    }
    func sample() {
        if !dragging, let index = slotIndex(in: tiles()) { currentIndex = index }
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) } }
        guard result == KERN_SUCCESS else { return }
        let ticks = [info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3]
        if let last = lastTicks {
            let deltas = zip(ticks, last).map { Double($0 &- $1) }
            let total = deltas.reduce(0, +)
            graph.cpu.append(total > 0 ? 1 - deltas[Int(CPU_STATE_IDLE)] / total : 0)
        }
        lastTicks = ticks
        var vm = vm_statistics64_data_t()
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let vmResult = withUnsafeMutablePointer(to: &vm) { p in p.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) } }
        if vmResult == KERN_SUCCESS {
            let pages = Double(vm.active_count) + Double(vm.inactive_count) + Double(vm.wire_count) + Double(vm.compressor_page_count) - Double(vm.purgeable_count) - Double(vm.external_page_count)
            let fraction = pages * Double(vm_kernel_page_size) / Double(ProcessInfo.processInfo.physicalMemory)
            graph.memory.append(max(0, min(1, fraction)))
        }
        graph.cpu = Array(graph.cpu.suffix(60)); graph.memory = Array(graph.memory.suffix(60)); graph.needsDisplay = true
        sampleCount += 1
        if sampleCount % 5 == 0 { print("sample=\(sampleCount) cpu=\(graph.cpu.last ?? 0) memory=\(graph.memory.last ?? 0) frame=\(panel.frame) visible=\(panel.isVisible)"); fflush(stdout) }
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Delegate(); app.delegate = delegate
let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler { NSApp.terminate(nil) }
    source.resume()
    return source
}
app.run()
