import AppKit
import SwiftUI

func studioIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 512, height: 512))
    image.lockFocus()
    NSColor(calibratedRed: 0.10, green: 0.115, blue: 0.145, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 28, y: 28, width: 456, height: 456), xRadius: 110, yRadius: 110).fill()
    NSColor(calibratedWhite: 1, alpha: 0.10).setFill()
    NSBezierPath(roundedRect: NSRect(x: 66, y: 163, width: 380, height: 172), xRadius: 40, yRadius: 40).fill()
    NSColor(calibratedWhite: 0.82, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 89, y: 208, width: 60, height: 80), xRadius: 17, yRadius: 17).fill()
    NSBezierPath(roundedRect: NSRect(x: 363, y: 208, width: 60, height: 80), xRadius: 17, yRadius: 17).fill()
    NSColor(calibratedRed: 0.70, green: 0.79, blue: 0.98, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 168, y: 208, width: 175, height: 80), xRadius: 17, yRadius: 17).fill()
    NSColor(calibratedRed: 0.20, green: 0.29, blue: 0.45, alpha: 1).setStroke()
    let line = NSBezierPath(); line.lineWidth = 6; line.lineCapStyle = .round; line.lineJoinStyle = .round
    line.move(to: NSPoint(x: 191, y: 243)); line.line(to: NSPoint(x: 219, y: 243)); line.line(to: NSPoint(x: 234, y: 263)); line.line(to: NSPoint(x: 253, y: 230)); line.line(to: NSPoint(x: 272, y: 252)); line.line(to: NSPoint(x: 317, y: 252)); line.stroke()
    image.unlockFocus(); return image
}

if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--export-icon" {
    let image = studioIcon()
    if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
    exit(0)
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var store: StudioStore!
    var window: NSWindow!
    var status: NSStatusItem!
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = studioIcon()
        store = StudioStore(); store.startOverlays()
        let menu = NSMenu()
        let appMenu = NSMenu(); let root = NSMenuItem(); root.submenu = appMenu; menu.addItem(root)
        appMenu.addItem(withTitle: "Open Dock Studio", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit and restore Dock", action: #selector(quit), keyEquivalent: "q").target = self
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""); let edit = NSMenu(title: "Edit"); editRoot.submenu = edit; menu.addItem(editRoot)
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840), styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Dock Studio"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.15, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua); window.isReleasedWhenClosed = false; window.delegate = self
        window.minSize = NSSize(width: 1100, height: 700)
        window.contentView = NSHostingView(rootView: StudioView(store: store))
        window.center(); window.setFrameAutosaveName("DockStudioMain")
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "rectangle.bottomthird.inset.filled", accessibilityDescription: "Dock Studio")
        let statusMenu = NSMenu()
        statusMenu.addItem(withTitle: "Open Dock Studio", action: #selector(showWindow), keyEquivalent: "").target = self
        statusMenu.addItem(.separator())
        statusMenu.addItem(withTitle: "Quit and restore Dock", action: #selector(quit), keyEquivalent: "").target = self
        status.menu = statusMenu
        NotificationCenter.default.addObserver(self, selector: #selector(showWindow), name: .studioShowWindow, object: nil)
        showWindow()
    }
    @objc func showWindow() { NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store != nil, !store.restoreDockOnQuit() else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "The Dock layout changed outside Dock Studio"
        alert.informativeText = "The widget slots could not be identified safely. Keep running to check the layout, or quit and leave those slots untouched."
        alert.addButton(withTitle: "Keep running"); alert.addButton(withTitle: "Quit without restoring")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(); app.delegate = delegate
    let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }; source.resume(); return source
    }
    withExtendedLifetime((delegate, signals)) { app.run() }
}
