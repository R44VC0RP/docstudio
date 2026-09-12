import AppKit
import SwiftUI
import ApplicationServices

@MainActor final class StudioStore: ObservableObject {
    @Published var draft: [DockEntry] = []
    @Published var applied: [DockEntry] = []
    @Published var pinned: [PinnedItem] = []
    @Published var selectedID: String?
    @Published var category = "All widgets"
    @Published var search = ""
    @Published var message: String?
    @Published var isError = false
    @Published var applying = false
    @Published var catalog: [WidgetKind: WidgetInstance] = Dictionary(uniqueKeysWithValues: WidgetKind.allCases.map { ($0, WidgetInstance(kind: $0)) })
    let telemetry = Telemetry()
    let timers = WidgetTimers()
    var overlays: DockOverlays?
    var placements: [WidgetPlacement] = []
    private var baselineKeys: [String] = []
    private var appliedKeys: [String] = []
    private var reloadTimer: Timer?
    private let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Dock Studio", isDirectory: true)
    private var stateURL: URL { folder.appendingPathComponent("layout.json") }
    var widgetCount: Int { draft.filter { $0.widget != nil }.count }
    var totalUnits: Int { draft.compactMap(\.widget).reduce(0) { $0 + $1.units } }
    var hasChanges: Bool { draft != applied }
    var selectedWidget: WidgetInstance? {
        if let widget = draft.first(where: { $0.id == selectedID })?.widget { return widget }
        if let selectedID, selectedID.hasPrefix("catalog:"), let kind = WidgetKind(rawValue: String(selectedID.dropFirst(8))) { return catalog[kind] }
        return nil
    }
    var selectionIsPlaced: Bool { draft.contains { $0.id == selectedID && $0.widget != nil } }
    var filteredKinds: [WidgetKind] {
        WidgetKind.allCases.filter { (category == "All widgets" || $0.category == category) && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.detail.localizedCaseInsensitiveContains(search)) }
    }
    init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let saved = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(SavedLayout.self, from: $0) }
        let current = Self.readDock()
        let owned = saved.flatMap { Self.ownedIndices(in: current, placements: $0.placements, appKeys: $0.appliedAppKeys) } ?? []
        let raw = current.enumerated().filter { !owned.contains($0.offset) }.map(\.element)
        pinned = Self.pinnedItems(raw)
        baselineKeys = pinned.map(\.id)
        let base = pinned.map { DockEntry.app($0.id) }
        if let saved, !owned.isEmpty {
            placements = Self.relocated(saved.placements, indices: owned)
            applied = Self.layout(pinned: pinned, groups: placements, count: current.count); appliedKeys = baselineKeys
        } else { applied = base; appliedKeys = baselineKeys }
        if let saved {
            var included = Set<String>()
            draft = saved.draft.filter { entry in
                if entry.widget != nil { return true }
                guard let key = entry.appKey, baselineKeys.contains(key) else { return false }
                return included.insert(key).inserted
            }
            draft.append(contentsOf: baselineKeys.filter { !included.contains($0) }.map { .app($0) })
        } else { draft = applied }
        selectedID = draft.first(where: { $0.widget != nil })?.id ?? "catalog:system"
        if !placements.isEmpty && !AXIsProcessTrusted() { message = "Allow Accessibility to reconnect your Dock widgets."; isError = true }
    }
    func startOverlays() {
        overlays = DockOverlays(telemetry: telemetry, timers: timers) { [weak self] widget in
            if widget.kind.isTimer { self?.timers.toggle(widget) }
            else { self?.selectedID = "widget:\(widget.id.uuidString)"; NotificationCenter.default.post(name: .studioShowWindow, object: nil) }
        }
        overlays?.update(placements)
    }
    func selectCatalog(_ kind: WidgetKind) { selectedID = "catalog:\(kind.rawValue)" }
    func add(_ kind: WidgetKind, before target: String? = nil) {
        var widget = catalog[kind] ?? WidgetInstance(kind: kind); widget.id = UUID()
        let entry = DockEntry.widget(widget)
        let index = target.flatMap { id in draft.firstIndex { $0.id == id } } ?? draft.count
        draft.insert(entry, at: index); selectedID = entry.id; changed()
    }
    func acceptDrop(_ token: String, before target: String?) {
        guard !applying else { return }
        if token.hasPrefix("catalog:"), let kind = WidgetKind(rawValue: String(token.dropFirst(8))) { add(kind, before: target) }
        else if token.hasPrefix("entry:") {
            let id = String(token.dropFirst(6)); guard id != target, let old = draft.firstIndex(where: { $0.id == id }) else { return }
            let item = draft.remove(at: old)
            let index = target.flatMap { id in draft.firstIndex { $0.id == id } } ?? draft.count
            draft.insert(item, at: index); selectedID = item.id; changed()
        }
    }
    func updateSelected(_ update: (inout WidgetInstance) -> Void) {
        if let index = draft.firstIndex(where: { $0.id == selectedID }), var widget = draft[index].widget {
            update(&widget); widget.units = min(4, max(2, widget.units)); draft[index].widget = widget; changed()
        } else if var widget = selectedWidget {
            update(&widget); catalog[widget.kind] = widget
        }
    }
    func removeSelected() {
        guard selectionIsPlaced else { return }
        draft.removeAll { $0.id == selectedID }; selectedID = nil; changed()
    }
    func moveSelected(_ direction: Int) {
        guard let index = draft.firstIndex(where: { $0.id == selectedID }), draft.indices.contains(index + direction) else { return }
        draft.swapAt(index, index + direction); changed()
    }
    func revert() { draft = applied; selectedID = draft.first(where: { $0.widget != nil })?.id; changed() }
    func changed() { message = nil; isError = false; persist() }
    func permission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func apply() {
        guard !applying else { return }
        guard AXIsProcessTrusted() else { message = "Allow Dock Studio in Accessibility, then apply again."; isError = true; permission(); return }
        let orientation = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        guard orientation == "bottom" else { message = "This version needs a bottom-positioned Dock."; isError = true; return }
        let current = Self.readDock()
        let own: Set<Int>
        if placements.isEmpty { own = [] }
        else if let indices = Self.ownedIndices(in: current, placements: placements, appKeys: appliedKeys) { own = indices }
        else { message = "The Dock changed outside Dock Studio. Reload the layout before applying."; isError = true; return }
        let currentKeys = Self.keys(current.enumerated().filter { !own.contains($0.offset) }.map(\.element))
        let expected = appliedKeys
        guard currentKeys == expected else { message = "Your pinned apps changed. Reload the layout before applying."; isError = true; return }
        guard Set(draft.compactMap(\.appKey)) == Set(baselineKeys), draft.compactMap(\.appKey).count == baselineKeys.count else { message = "The layout must keep each of your pinned apps exactly once."; isError = true; return }
        let currentApps = current.enumerated().filter { !own.contains($0.offset) }.map(\.element)
        let lookup = Dictionary(uniqueKeysWithValues: zip(Self.keys(currentApps), currentApps))
        var output: [[String: Any]] = [], groups: [WidgetPlacement] = []
        for entry in draft {
            if let widget = entry.widget {
                groups.append(WidgetPlacement(widget: widget, index: output.count))
                output.append(contentsOf: (0..<widget.units).map { _ in ["tile-type": "spacer-tile", "tile-data": [:]] })
            } else if let key = entry.appKey, let raw = lookup[key] { output.append(raw) }
        }
        let newOwn = Set(groups.flatMap { Array($0.index..<($0.index + $0.widget.units)) })
        let newPins = Self.pinnedItems(output.enumerated().filter { !newOwn.contains($0.offset) }.map(\.element))
        let normalized = Self.layout(pinned: newPins, groups: groups, count: output.count)
        let staged = SavedLayout(draft: normalized, applied: normalized, placements: groups, appliedAppKeys: newPins.map(\.id))
        do {
            // Recovery and ownership must be durable before touching the real Dock.
            let backup = try PropertyListSerialization.data(fromPropertyList: current, format: .binary, options: 0)
            try backup.write(to: folder.appendingPathComponent("before-apply.plist"), options: .atomic)
            try writeState(staged)
        } catch { message = "Couldn’t save the layout safely: \(error.localizedDescription)"; isError = true; return }
        let oldPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        applying = true; message = nil; isError = false
        overlays?.hide()
        do { try Self.writeDock(output) }
        catch {
            CFPreferencesSetAppValue("persistent-apps" as CFString, current as CFArray, "com.apple.dock" as CFString)
            CFPreferencesAppSynchronize("com.apple.dock" as CFString)
            persist(); overlays?.update(placements); applying = false
            message = "Couldn’t apply the Dock layout: \(error.localizedDescription)"; isError = true; return
        }
        pinned = newPins; baselineKeys = newPins.map(\.id)
        applied = normalized; draft = normalized; placements = groups; appliedKeys = baselineKeys
        overlays?.update(groups)
        let started = ProcessInfo.processInfo.systemUptime
        reloadTimer?.invalidate()
        reloadTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
            guard let self else { timer.invalidate(); return }
            let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
            let actual = Self.readDock()
            let actualOwn = Self.ownedIndices(in: actual, placements: self.placements, appKeys: self.appliedKeys)
            let matches = actualOwn.map { indices in Self.keys(actual.enumerated().filter { !indices.contains($0.offset) }.map(\.element)) == self.appliedKeys } ?? false
            if pid != nil && pid != oldPID && matches && (self.placements.isEmpty || self.overlays?.allVisible == true) {
                self.applying = false; self.message = "Applied to your Dock"; self.isError = false; timer.invalidate()
            } else if ProcessInfo.processInfo.systemUptime - started > 6 {
                self.applying = false; self.message = "Layout saved. The Dock is not visible yet; check Accessibility and auto-hide."; self.isError = true; timer.invalidate()
            }
            }
        }
    }
    func reloadLayout() {
        if hasChanges {
            let alert = NSAlert(); alert.messageText = "Reload your current Dock?"; alert.informativeText = "This replaces unapplied changes in the preview."; alert.addButton(withTitle: "Reload"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let current = Self.readDock()
        let own = Self.ownedIndices(in: current, placements: placements, appKeys: appliedKeys) ?? []
        if !placements.isEmpty && own.isEmpty { message = "Could not identify the widget slots safely. Quit and restore the Dock before reloading."; isError = true; return }
        pinned = Self.pinnedItems(current.enumerated().filter { !own.contains($0.offset) }.map(\.element))
        baselineKeys = pinned.map(\.id)
        placements = Self.relocated(placements, indices: own)
        let entries = Self.layout(pinned: pinned, groups: placements, count: current.count)
        applied = entries; draft = entries; appliedKeys = entries.compactMap(\.appKey); overlays?.update(placements); changed()
    }
    func restoreDockOnQuit() -> Bool {
        guard !placements.isEmpty else { overlays?.stop(); return true }
        let current = Self.readDock()
        guard let own = Self.ownedIndices(in: current, placements: placements, appKeys: appliedKeys) else { return false }
        do { try Self.writeDock(current.enumerated().filter { !own.contains($0.offset) }.map(\.element)) }
        catch { return false } // Keep ownership data for recovery on the next launch.
        reloadTimer?.invalidate(); overlays?.stop()
        placements = []; applied = pinned.map { .app($0.id) }; appliedKeys = baselineKeys; persist(); return true
    }
    private func writeState(_ state: SavedLayout) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateURL.path)
    }
    private func persist() {
        do { try writeState(SavedLayout(draft: draft, applied: applied, placements: placements, appliedAppKeys: appliedKeys)) }
        catch { message = "Couldn’t save your changes: \(error.localizedDescription)"; isError = true }
    }
    static func readDock() -> [[String: Any]] {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("persistent-apps" as CFString, domain) as? [[String: Any]] ?? []
    }
    static func writeDock(_ entries: [[String: Any]]) throws {
        let domain = "com.apple.dock" as CFString
        CFPreferencesSetAppValue("persistent-apps" as CFString, entries as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw NSError(domain: "DockStudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS could not save Dock preferences."]) }
        // SIGTERM on macOS 27 can flush the old list over the newly saved layout.
        let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/bin/killall"); task.arguments = ["-KILL", "Dock"]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw NSError(domain: "DockStudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "The Dock could not be reloaded."]) }
    }
    static func keys(_ entries: [[String: Any]]) -> [String] {
        var seen: [String: Int] = [:]
        return entries.map { item in
            let data = item["tile-data"] as? [String: Any] ?? [:]
            let file = data["file-data"] as? [String: Any] ?? [:]
            let base = file["_CFURLString"] as? String ?? "system:\(item["tile-type"] as? String ?? "item")"
            let ordinal = seen[base, default: 0]; seen[base] = ordinal + 1
            return "\(base)#\(ordinal)"
        }
    }
    static func pinnedItems(_ entries: [[String: Any]]) -> [PinnedItem] {
        zip(keys(entries), entries).map { key, raw in
            let data = raw["tile-data"] as? [String: Any] ?? [:]
            let file = data["file-data"] as? [String: Any] ?? [:]
            let url = (file["_CFURLString"] as? String).flatMap(URL.init(string:))
            let title = data["file-label"] as? String ?? url?.deletingPathExtension().lastPathComponent ?? "Spacer"
            let icon = url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(systemSymbolName: "minus", accessibilityDescription: "Spacer")!
            return PinnedItem(id: key, title: title.isEmpty ? "Spacer" : title, icon: icon, raw: raw)
        }
    }
    static func ownedIndices(in entries: [[String: Any]], placements: [WidgetPlacement], appKeys: [String]) -> Set<Int>? {
        guard !placements.isEmpty else { return [] }
        let sorted = placements.sorted { $0.index < $1.index }
        var blocks: [(index: Int, count: Int)] = []
        for group in sorted {
            guard (2...4).contains(group.widget.units), group.index >= 0 else { return nil }
            if let last = blocks.last, last.index + last.count == group.index { blocks[blocks.count - 1].count += group.widget.units }
            else { blocks.append((group.index, group.widget.units)) }
        }
        func base(_ key: String) -> String { key.lastIndex(of: "#").map { String(key[..<$0]) } ?? key }
        func rawBase(_ item: [String: Any]) -> String { base(keys([item])[0]) }
        var own = Set<Int>(), precedingUnits = 0
        for block in blocks {
            guard entries.count >= block.count else { return nil }
            let rank = block.index - precedingUnits
            let left = rank > 0 && rank <= appKeys.count ? base(appKeys[rank - 1]) : nil
            let right = rank >= 0 && rank < appKeys.count ? base(appKeys[rank]) : nil
            var candidates: [(index: Int, score: Int)] = []
            for index in 0...(entries.count - block.count) {
                let range = index..<(index + block.count)
                guard range.allSatisfy({ entries[$0]["tile-type"] as? String == "spacer-tile" && !own.contains($0) }) else { continue }
                let before = index > 0 ? rawBase(entries[index - 1]) : nil
                let after = range.upperBound < entries.count ? rawBase(entries[range.upperBound]) : nil
                // Never absorb extra, user-created adjacent spacers into our block.
                if before == "system:spacer-tile" && left != before { continue }
                if after == "system:spacer-tile" && right != after { continue }
                let score = (left != nil && left == before ? 2 : left == nil && index == 0 ? 1 : 0)
                    + (right != nil && right == after ? 2 : right == nil && range.upperBound == entries.count ? 1 : 0)
                if score > 0 { candidates.append((index, score)) }
            }
            guard let best = candidates.map(\.score).max(), candidates.filter({ $0.score == best }).count == 1,
                  let match = candidates.first(where: { $0.score == best }) else { return nil }
            own.formUnion(match.index..<(match.index + block.count)); precedingUnits += block.count
        }
        return own
    }
    static func relocated(_ groups: [WidgetPlacement], indices: Set<Int>) -> [WidgetPlacement] {
        let positions = indices.sorted(); var cursor = 0
        return groups.sorted { $0.index < $1.index }.compactMap { group in
            guard cursor < positions.count else { return nil }
            let index = positions[cursor]; cursor += group.widget.units
            return WidgetPlacement(widget: group.widget, index: index)
        }
    }
    static func layout(pinned: [PinnedItem], groups: [WidgetPlacement], count: Int) -> [DockEntry] {
        let byStart = Dictionary(uniqueKeysWithValues: groups.map { ($0.index, $0.widget) })
        var result: [DockEntry] = [], rawIndex = 0, appIndex = 0
        while rawIndex < count {
            if let widget = byStart[rawIndex] { result.append(.widget(widget)); rawIndex += widget.units }
            else { if appIndex < pinned.count { result.append(.app(pinned[appIndex].id)); appIndex += 1 }; rawIndex += 1 }
        }
        return result
    }
}

extension Notification.Name { static let studioShowWindow = Notification.Name("DockStudio.showWindow") }
