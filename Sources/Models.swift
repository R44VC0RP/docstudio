import AppKit
import SwiftUI

// The catalog is deliberately local-first: every widget works without an account.
enum WidgetKind: String, CaseIterable, Codable, Identifiable {
    case system, cpu, memory, network, storage, battery, clock, worldClock, calendar, focus, stopwatch, countdown, uptime, load, thermal, note
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "CPU + memory"
        case .cpu: return "Processor"
        case .memory: return "Memory"
        case .network: return "Network"
        case .storage: return "Storage"
        case .battery: return "Power"
        case .clock: return "Local time"
        case .worldClock: return "World clock"
        case .calendar: return "Calendar"
        case .focus: return "Focus timer"
        case .stopwatch: return "Stopwatch"
        case .countdown: return "Countdown"
        case .uptime: return "Uptime"
        case .load: return "System load"
        case .thermal: return "Thermal state"
        case .note: return "Quick note"
        }
    }
    var symbol: String {
        switch self {
        case .system: return "waveform.path.ecg"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "arrow.up.arrow.down"
        case .storage: return "internaldrive"
        case .battery: return "bolt"
        case .clock: return "clock"
        case .worldClock: return "globe"
        case .calendar: return "calendar"
        case .focus: return "circle.dotted"
        case .stopwatch: return "stopwatch"
        case .countdown: return "hourglass"
        case .uptime: return "power"
        case .load: return "chart.bar"
        case .thermal: return "thermometer.medium"
        case .note: return "text.alignleft"
        }
    }
    var category: String {
        switch self {
        case .system, .cpu, .memory, .network, .storage, .battery, .uptime, .load, .thermal: return "System"
        case .clock, .worldClock, .calendar, .focus, .stopwatch, .countdown: return "Time"
        case .note: return "Personal"
        }
    }
    var detail: String {
        switch self {
        case .system: return "Two live graphs, one glance."
        case .cpu: return "Processor use over the last minute."
        case .memory: return "Used memory, excluding cached files."
        case .network: return "Live download and upload speeds."
        case .storage: return "Space used on your startup volume."
        case .battery: return "Battery level or connected power."
        case .clock: return "Your local time, always in view."
        case .worldClock: return "A second time zone alongside yours."
        case .calendar: return "Today’s date and the week ahead."
        case .focus: return "A focus session you can start and pause."
        case .stopwatch: return "Track elapsed time with a click."
        case .countdown: return "A simple countdown for what’s next."
        case .uptime: return "Time since your Mac last restarted."
        case .load: return "One, five, and fifteen-minute system load."
        case .thermal: return "Your Mac’s reported thermal state."
        case .note: return "Keep one small note in sight."
        }
    }
    var defaultAccent: WidgetAccent {
        switch self {
        case .memory, .worldClock, .focus: return .violet
        case .battery, .storage, .uptime: return .mint
        case .calendar, .countdown, .thermal: return .amber
        case .note, .stopwatch: return .rose
        default: return .cyan
        }
    }
    var isTimer: Bool { self == .focus || self == .stopwatch || self == .countdown }
}

enum WidgetAccent: String, CaseIterable, Codable, Identifiable {
    case cyan, violet, mint, amber, rose
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .cyan: return Color(red: 0.43, green: 0.82, blue: 0.94)
        case .violet: return Color(red: 0.73, green: 0.65, blue: 0.98)
        case .mint: return Color(red: 0.52, green: 0.84, blue: 0.69)
        case .amber: return Color(red: 0.96, green: 0.75, blue: 0.42)
        case .rose: return Color(red: 0.96, green: 0.62, blue: 0.70)
        }
    }
}

struct WidgetInstance: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var units = 2
    var accent: WidgetAccent
    var note = ""
    var durationMinutes: Int
    var timeZone = "Europe/London"
    var use24Hour = true
    init(kind: WidgetKind) {
        self.kind = kind
        self.accent = kind.defaultAccent
        self.durationMinutes = kind == .countdown ? 10 : 25
    }
}

struct DockEntry: Codable, Identifiable, Equatable {
    var appKey: String?
    var widget: WidgetInstance?
    var id: String { widget.map { "widget:\($0.id.uuidString)" } ?? "app:\(appKey ?? "")" }
    static func app(_ key: String) -> DockEntry { DockEntry(appKey: key) }
    static func widget(_ widget: WidgetInstance) -> DockEntry { DockEntry(widget: widget) }
}

struct PinnedItem: Identifiable {
    let id: String
    let title: String
    let icon: NSImage
    let raw: [String: Any]
}

struct WidgetPlacement: Codable {
    let widget: WidgetInstance
    let index: Int
}

struct SavedLayout: Codable {
    var draft: [DockEntry]
    var applied: [DockEntry]
    var placements: [WidgetPlacement]
    var appliedAppKeys: [String]
}

struct TimerState {
    var started: Date?
    var accumulated: TimeInterval = 0
    func elapsed(at now: Date) -> TimeInterval { accumulated + (started.map { max(0, now.timeIntervalSince($0)) } ?? 0) }
}

@MainActor final class WidgetTimers: ObservableObject {
    @Published var states: [UUID: TimerState] = [:]
    func toggle(_ widget: WidgetInstance) {
        var state = states[widget.id] ?? TimerState()
        if let started = state.started {
            state.accumulated += Date().timeIntervalSince(started); state.started = nil
        } else {
            if widget.kind != .stopwatch && state.accumulated >= Double(widget.durationMinutes * 60) { state.accumulated = 0 }
            state.started = Date()
        }
        states[widget.id] = state
    }
    func reset(_ widget: WidgetInstance) { states[widget.id] = TimerState() }
    func elapsed(_ widget: WidgetInstance, at now: Date) -> TimeInterval { states[widget.id]?.elapsed(at: now) ?? 0 }
    func isRunning(_ widget: WidgetInstance) -> Bool { states[widget.id]?.started != nil }
}

extension Font {
    static func studio(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { .custom("Helvetica Neue", size: size).weight(weight) }
}
