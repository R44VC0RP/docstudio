import AppKit
import ApplicationServices
import Darwin

let domain = "com.apple.dock" as CFString
let slotIDs = [927611021, 927611022]
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
    // macOS 27 strips spacer GUIDs. These test slots are deliberately fixed
    // immediately after Finder; never remove spacers elsewhere in the Dock.
    guard old.count >= 2, old.prefix(2).allSatisfy({ ($0["tile-type"] as? String) == "spacer-tile" }) else { return }
    setTiles(Array(old.dropFirst(2)))
}
if CommandLine.arguments.contains("--cleanup") { removeSlots(); exit(0) }
guard (tiles().first?["tile-type"] as? String) != "spacer-tile" else { fputs("Leading spacers already exist; remove this experiment with --cleanup before relaunching.\n", stderr); exit(1) }
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
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.075, alpha: 0.97).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
        let colors = [NSColor(calibratedRed: 0.36, green: 0.84, blue: 0.96, alpha: 1), NSColor(calibratedRed: 0.75, green: 0.64, blue: 1, alpha: 1)]
        for (i, data) in [cpu, memory].enumerated() {
            let row = bounds.height / 2
            let y = bounds.height - CGFloat(i + 1) * row
            let font = NSFont(name: "Helvetica Neue", size: max(8, min(11, row * 0.43)))!
            let value = data.last ?? 0
            let label = "\(i == 0 ? "CPU" : "Mem") \(Int(value * 100))%"
            (label as NSString).draw(at: CGPoint(x: 6, y: y + row - font.pointSize - 3), withAttributes: [.font: font, .foregroundColor: colors[i]])
            let graph = CGRect(x: 6, y: y + 3, width: bounds.width - 12, height: max(4, row - font.pointSize - 7))
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        let existing = tiles()
        let backup = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dock-2u-before.plist")
        if !FileManager.default.fileExists(atPath: backup.path), let data = try? PropertyListSerialization.data(fromPropertyList: existing, format: .xml, options: 0) { try? data.write(to: backup) }
        let clean = existing.filter { !slotIDs.contains($0["GUID"] as? Int ?? 0) }
        setTiles(slotIDs.map { ["GUID": $0, "tile-type": "spacer-tile", "tile-data": [:]] as [String: Any] } + clean)
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 86, height: 41), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Dock 2U CPU and memory"
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false; panel.ignoresMouseEvents = true
        panel.contentView = graph
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
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { panel.orderOut(nil); return }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        guard let list = (attr(root, "AXChildren") as? [AXUIElement])?.first,
              let items = attr(list, "AXChildren") as? [AXUIElement], items.count > 3,
              (attr(items[1], "AXTitle") as? String ?? "").isEmpty,
              (attr(items[2], "AXTitle") as? String ?? "").isEmpty,
              let a = rect(items[1]), let b = rect(items[2]), a.width > 20, b.width > 20,
              abs(a.minY - b.minY) < 30 else { panel.orderOut(nil); return }
        let union = a.union(b)
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let height = min(a.width, b.width) - 2
        let frame = CGRect(x: union.minX + 2, y: desktopTop - union.minY - height - 6, width: union.width - 4, height: height)
        guard NSScreen.screens.contains(where: { $0.frame.intersects(frame) }), frame.minY >= 0 else { panel.orderOut(nil); return }
        panel.setFrame(frame, display: true); panel.orderFrontRegardless()
    }
    func sample() {
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
