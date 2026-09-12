import SwiftUI

/// The face of one widget: a flat, near-black rounded surface whose content scales with its height.
/// Sizes are designed in a 64-unit-high space (padding 9, value 22, label 15) and multiplied by `scale`.
@MainActor struct WidgetFace: View {
    let widget: WidgetInstance
    @ObservedObject var telemetry: Telemetry
    @ObservedObject var timers: WidgetTimers

    private struct Metrics {
        let scale: CGFloat
        let width: CGFloat  // available width in 64-baseline units: 2U ≈ 147, catalog ≈ 156, 3U ≈ 230, 4U ≈ 314
        var wide: Bool { width >= 190 }
        func u(_ units: CGFloat) -> CGFloat { units * scale }
    }

    private let secondary = Color.white.opacity(0.5)
    private let track = Color.white.opacity(0.12)
    private var accent: Color { widget.accent.color }

    var body: some View {
        GeometryReader { proxy in
            let scale = max(proxy.size.height, 8) / 64
            let m = Metrics(scale: scale, width: proxy.size.width / scale)
            content(m)
                .padding(m.u(9))
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
                .background(Color(white: 0.075), in: RoundedRectangle(cornerRadius: m.u(12), style: .continuous))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(widget.kind.title)
    }

    @ViewBuilder private func content(_ m: Metrics) -> some View {
        switch widget.kind {
        case .system:
            VStack(spacing: m.u(4)) {
                row(Text("CPU"), telemetry.cpuHistory.isEmpty ? "—" : percent(telemetry.cpu), telemetry.cpuHistory, peak: 1, m)
                row(Text("Mem"), percent(telemetry.memory), telemetry.memoryHistory, peak: 1, m)
            }
        case .cpu:
            HStack(spacing: m.u(8)) {
                stack(telemetry.cpuHistory.isEmpty ? "—" : percent(telemetry.cpu), "CPU", m)
                ZStack {
                    Sparkline(values: telemetry.cpuHistory, closed: true).fill(accent.opacity(0.18))
                    Sparkline(values: telemetry.cpuHistory).stroke(accent, style: stroke(m))
                }
                .padding(.vertical, m.u(1))
            }
        case .memory:
            gauge(gigabytes(telemetry.memoryUsedBytes, decimals: 1), "of \(gigabytes(telemetry.memoryTotalBytes, decimals: 0))", fraction: telemetry.memory, m)
        case .network:
            let peak = max(50_000, (telemetry.downloadHistory + telemetry.uploadHistory).max() ?? 0)
            VStack(spacing: m.u(4)) {
                row(Image(systemName: "arrow.down"), rate(telemetry.downloadBytesPerSecond, telemetry.downloadHistory), telemetry.downloadHistory, peak: peak, slot: 92, m)
                row(Image(systemName: "arrow.up"), rate(telemetry.uploadBytesPerSecond, telemetry.uploadHistory), telemetry.uploadHistory, peak: peak, slot: 92, m)
            }
        case .storage:
            let total = telemetry.storageTotalBytes, used = telemetry.storageUsedBytes
            let free = Telemetry.formatBytes(max(0, total - used))
            gauge(total > 0 ? Telemetry.formatBytes(used) : "—",
                  total > 0 ? (m.wide ? "\(free) free of \(Telemetry.formatBytes(total))" : "\(free) free") : "Reading volume",
                  fraction: total > 0 ? used / total : 0, m)
        case .battery:
            if let fraction = telemetry.batteryFraction {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: m.u(6)) {
                        BatteryGlyph(fraction: fraction, fill: accent, shell: secondary).frame(width: m.u(26), height: m.u(13))
                        value(percent(fraction), m)
                    }
                    label(telemetry.isCharging ? "Charging" : telemetry.powerSource, m)
                }
            } else {
                stack(telemetry.powerSource, "No battery", m)
            }
        case .clock:
            stack(time(telemetry.now, seconds: true), date(telemetry.now, template: m.wide ? "EEEEdMMMM" : "EEEdMMM"), m)
        case .worldClock:
            let zone = TimeZone(identifier: widget.timeZone) ?? .current
            let city = widget.timeZone.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? widget.timeZone
            let hours = Double(zone.secondsFromGMT(for: telemetry.now) - TimeZone.current.secondsFromGMT(for: telemetry.now)) / 3600
            let offset = hours == 0 ? "same time" : String(format: hours == hours.rounded() ? "%+.0f h" : "%+.1f h", hours).replacingOccurrences(of: "-", with: "−")
            stack(time(telemetry.now, seconds: false, zone: zone), "\(city), \(offset)", m)
        case .calendar:
            let calendar = Calendar.current, now = telemetry.now
            HStack(spacing: m.u(8)) {
                stack("\(calendar.component(.day, from: now))", "\(date(now, template: "EEEE")), week \(calendar.component(.weekOfYear, from: now))", m)
                if m.width >= 250, let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start {
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { offset in
                            let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                            let today = calendar.isDate(day, inSameDayAs: now)
                            Text("\(calendar.component(.day, from: day))")
                                .font(.studio(m.u(14), weight: today ? .medium : .regular))
                                .foregroundStyle(today ? accent : day < now ? Color.white.opacity(0.3) : secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        case .focus, .countdown:
            let elapsed = timers.elapsed(widget, at: telemetry.now), running = timers.isRunning(widget)
            let duration = Double(max(1, widget.durationMinutes) * 60), done = elapsed >= duration
            let countdown = widget.kind == .countdown
            let shown = countdown ? max(0, duration - elapsed) : min(elapsed, duration)
            let state = elapsed == 0 && !running ? "\(widget.durationMinutes) min"
                : done ? (countdown ? "Time’s up" : "Complete") : running ? (countdown ? "Running" : "Focusing") : "Paused"
            HStack(spacing: m.u(8)) {
                stack(clock(shown), state, m)
                Spacer(minLength: 0)
                Ring(progress: shown / duration, color: running || done ? accent : secondary, track: track, lineWidth: m.u(4))
                    .frame(width: m.u(40), height: m.u(40))
            }
        case .stopwatch:
            let elapsed = timers.elapsed(widget, at: telemetry.now), running = timers.isRunning(widget)
            stack(clock(elapsed), running ? "Running" : elapsed > 0 ? "Paused" : "Ready", m)
        case .uptime:
            let seconds = Int(telemetry.uptime), days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
            let boot = telemetry.now.addingTimeInterval(-telemetry.uptime)
            let since = Calendar.current.isDateInToday(boot) ? time(boot, seconds: false)
                : days < 7 ? "\(date(boot, template: "EEE")) \(time(boot, seconds: false))" : date(boot, template: "dMMM")
            stack(days > 0 ? "\(days)d \(hours)h" : hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m", "Since \(since)", m)
        case .load:
            HStack(spacing: 0) {
                ForEach(Array(["1 min", "5 min", "15 min"].enumerated()), id: \.offset) { index, period in
                    let load = telemetry.loadAverages.count > index ? telemetry.loadAverages[index] : nil
                    stack(load.map { String(format: $0 >= 10 ? "%.1f" : "%.2f", $0) } ?? "—", period, m, size: 20)
                        .fixedSize(horizontal: true, vertical: false)
                    if index < 2 { Spacer(minLength: m.u(4)) }
                }
            }
        case .thermal:
            let level = ["Nominal", "Fair", "Serious", "Critical"].firstIndex(of: telemetry.thermalState) ?? -1
            VStack(alignment: .leading, spacing: 0) {
                value(telemetry.thermalState, m)
                HStack(spacing: m.u(5)) {
                    ForEach(0..<4, id: \.self) { step in
                        Circle().fill(step <= level ? accent : track).frame(width: m.u(7), height: m.u(7))
                    }
                }
                .frame(height: m.u(16))
            }
        case .note:
            let note = widget.note.trimmingCharacters(in: .whitespacesAndNewlines)
            Text(note.isEmpty ? "Add a note" : note)
                .font(.studio(m.u(16)))
                .foregroundStyle(note.isEmpty ? secondary : accent)
                .lineLimit(2)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }

    // MARK: Building blocks

    private func value(_ text: String, _ m: Metrics, size: CGFloat = 22) -> some View {
        Text(text).font(.studio(m.u(size), weight: .medium)).foregroundStyle(accent)
            .lineLimit(1).minimumScaleFactor(0.8).frame(height: m.u(24))
    }

    private func label(_ text: String, _ m: Metrics) -> some View {
        Text(text).font(.studio(m.u(15))).foregroundStyle(secondary).lineLimit(1).minimumScaleFactor(0.9).frame(height: m.u(16))
    }

    private func stack(_ primary: String, _ caption: String, _ m: Metrics, size: CGFloat = 22) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            value(primary, m, size: size)
            label(caption, m)
        }
    }

    /// Value and label above a full-width capacity bar (memory, storage).
    private func gauge(_ primary: String, _ caption: String, fraction: Double, _ m: Metrics) -> some View {
        VStack(alignment: .leading, spacing: m.u(2)) {
            stack(primary, caption, m)
            GeometryReader { bar in
                Capsule().fill(track)
                Capsule().fill(accent).frame(width: bar.size.width * min(1, max(0, fraction)))
            }
            .frame(height: m.u(4))
        }
    }

    /// One of two stacked rows: fixed-width label and value, then a sparkline that takes the remaining width.
    private func row<Label: View>(_ leading: Label, _ reading: String, _ history: [Double], peak: Double, slot: CGFloat = 80, _ m: Metrics) -> some View {
        HStack(spacing: m.u(6)) {
            HStack(alignment: .firstTextBaseline, spacing: m.u(4)) {
                leading.font(.studio(m.u(15))).foregroundStyle(secondary)
                Text(reading).font(.studio(m.u(15), weight: .medium)).foregroundStyle(accent)
            }
            .lineLimit(1)
            .frame(width: m.u(slot), alignment: .leading)
            Sparkline(values: history, peak: peak).stroke(accent, style: stroke(m)).padding(.vertical, m.u(1))
        }
        .frame(maxHeight: .infinity)
    }

    private func stroke(_ m: Metrics) -> StrokeStyle { StrokeStyle(lineWidth: m.u(1.5), lineCap: .round, lineJoin: .round) }

    // MARK: Formatting

    private func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

    private func gigabytes(_ bytes: Double, decimals: Int) -> String { String(format: "%.\(decimals)f GB", bytes / 1_073_741_824) }

    private func rate(_ bytesPerSecond: Double, _ history: [Double]) -> String { history.isEmpty ? "—" : Telemetry.formatRate(bytesPerSecond) }

    private func clock(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total % 3600 / 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    private func time(_ date: Date, seconds: Bool, zone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        formatter.dateFormat = widget.use24Hour ? (seconds ? "HH:mm:ss" : "HH:mm") : (seconds ? "h:mm:ss a" : "h:mm a")
        return formatter.string(from: date)
    }

    private func date(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}

/// Recent samples drawn right-aligned, so a partially filled history grows in from the trailing edge.
private struct Sparkline: Shape {
    var values: [Double]
    var peak: Double = 1
    var capacity = 60
    var closed = false

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard values.count > 1, peak > 0 else { return path }
        let step = rect.width / CGFloat(max(capacity, values.count) - 1)
        let points = values.enumerated().map { index, value in
            CGPoint(x: rect.maxX - CGFloat(values.count - 1 - index) * step,
                    y: rect.maxY - CGFloat(min(1, max(0, value / peak))) * rect.height)
        }
        path.addLines(points)
        if closed, let first = points.first, let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: rect.maxY))
            path.addLine(to: CGPoint(x: first.x, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

private struct Ring: View {
    let progress: Double
    let color: Color
    let track: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

private struct BatteryGlyph: View {
    let fraction: Double
    let fill: Color
    let shell: Color

    var body: some View {
        Canvas { context, size in
            let line = size.height * 0.1, nub = size.width * 0.08
            let body = CGRect(x: line / 2, y: line / 2, width: size.width - nub - line, height: size.height - line)
            context.stroke(Path(roundedRect: body, cornerRadius: size.height * 0.22), with: .color(shell), lineWidth: line)
            context.fill(Path(roundedRect: CGRect(x: body.maxX + line, y: size.height * 0.32, width: nub - line * 0.5, height: size.height * 0.36), cornerRadius: nub * 0.3), with: .color(shell))
            let cell = body.insetBy(dx: line * 1.5, dy: line * 1.5)
            context.fill(Path(roundedRect: CGRect(x: cell.minX, y: cell.minY, width: cell.width * min(1, max(0, fraction)), height: cell.height), cornerRadius: size.height * 0.1), with: .color(fill))
        }
    }
}
