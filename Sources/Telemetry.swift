import Combine
import Darwin
import Foundation
import IOKit.ps

@MainActor
final class Telemetry: ObservableObject {
    @Published var cpu: Double = 0
    @Published var memory: Double = 0
    @Published var memoryUsedBytes: Double = 0
    @Published var memoryTotalBytes: Double = Double(ProcessInfo.processInfo.physicalMemory)
    @Published var cpuHistory: [Double] = []
    @Published var memoryHistory: [Double] = []
    @Published var downloadBytesPerSecond: Double = 0
    @Published var uploadBytesPerSecond: Double = 0
    @Published var downloadHistory: [Double] = []
    @Published var uploadHistory: [Double] = []
    @Published var storageUsedBytes: Double = 0
    @Published var storageTotalBytes: Double = 0
    @Published var batteryFraction: Double?
    @Published var isCharging: Bool = false
    @Published var powerSource: String = "AC power"
    @Published var loadAverages: [Double] = [0, 0, 0]
    @Published var thermalState: String = "Nominal"
    @Published var uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    @Published var now: Date = Date()
    @Published var coreCount: Int = ProcessInfo.processInfo.processorCount

    private var timer: Timer?
    private var previousCPUTicks: [UInt64]?
    private var previousNetwork: (time: TimeInterval, interfaces: [String: InterfaceBytes])?
    private var lastStorageSample: TimeInterval?
    private let historyLimit = 60

    private struct InterfaceBytes {
        let received: UInt64
        let sent: UInt64
    }

    init() {
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        timer.tolerance = 0.1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    deinit {
        timer?.invalidate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let process = ProcessInfo.processInfo
        now = Date()
        uptime = process.systemUptime
        refreshCPU()
        refreshMemory()
        refreshNetwork(at: uptime)
        refreshPower()

        var averages = [Double](repeating: 0, count: 3)
        if getloadavg(&averages, 3) == 3 {
            loadAverages = averages
        }
        switch process.thermalState {
        case .nominal: thermalState = "Nominal"
        case .fair: thermalState = "Fair"
        case .serious: thermalState = "Serious"
        case .critical: thermalState = "Critical"
        @unknown default: thermalState = "Unknown"
        }

        if lastStorageSample == nil || uptime - (lastStorageSample ?? uptime) >= 15 {
            lastStorageSample = uptime
            refreshStorage()
        }
    }

    private func refreshCPU() {
        var statistics = host_cpu_load_info_data_t()
        let capacity = MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            previousCPUTicks = nil
            return
        }
        let ticks = [
            UInt64(statistics.cpu_ticks.0), UInt64(statistics.cpu_ticks.1),
            UInt64(statistics.cpu_ticks.2), UInt64(statistics.cpu_ticks.3)
        ]
        let previous = previousCPUTicks
        previousCPUTicks = ticks
        // The first read establishes a baseline; never invent preceding history.
        guard let previous, zip(ticks, previous).allSatisfy({ $0 >= $1 }) else { return }
        let delta = zip(ticks, previous).map { $0 - $1 }
        let total = delta.reduce(UInt64(0), +)
        guard total > 0 else { return }
        cpu = min(1, max(0, 1 - Double(delta[Int(CPU_STATE_IDLE)]) / Double(total)))
        append(cpu, to: &cpuHistory)
    }

    private func refreshMemory() {
        var statistics = vm_statistics64_data_t()
        let capacity = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(capacity)
        var pageSize: vm_size_t = 0
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        guard host_page_size(host, &pageSize) == KERN_SUCCESS, pageSize > 0 else { return }
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, memoryTotalBytes > 0 else { return }
        // Approximate Activity Monitor: anonymous + wired + compressed, excluding
        // reclaimable file-backed cache and purgeable pages. Speculative pages
        // are already included in free_count, so do not subtract them again.
        let usedPages = Double(statistics.internal_page_count)
            + Double(statistics.wire_count)
            + Double(statistics.compressor_page_count)
            - Double(statistics.purgeable_count)
        memoryUsedBytes = min(memoryTotalBytes, max(0, usedPages * Double(pageSize)))
        memory = memoryUsedBytes / memoryTotalBytes
        append(memory, to: &memoryHistory)
    }

    private func refreshNetwork(at time: TimeInterval) {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0 else {
            previousNetwork = nil
            return
        }
        defer { if let first { freeifaddrs(first) } }
        var interfaces: [String: InterfaceBytes] = [:]
        var cursor = first
        while let pointer = cursor {
            let interface = pointer.pointee
            cursor = interface.ifa_next
            guard let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  let namePointer = interface.ifa_name,
                  let data = interface.ifa_data,
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: namePointer)
            guard name.hasPrefix("en"), name.count > 2,
                  name.dropFirst(2).allSatisfy({ $0.isNumber }) else { continue }
            let counters = data.assumingMemoryBound(to: if_data.self).pointee
            guard counters.ifi_type == UInt8(IFT_ETHER) else { continue }
            // One AF_LINK entry per physical Ethernet/Wi-Fi interface, not its
            // IPv4/IPv6 addresses or the corresponding bridge/VPN interfaces.
            interfaces[name] = InterfaceBytes(
                received: UInt64(counters.ifi_ibytes), sent: UInt64(counters.ifi_obytes)
            )
        }
        let previous = previousNetwork
        previousNetwork = (time, interfaces)
        guard let previous else { return }
        let elapsed = time - previous.time
        guard elapsed > 0, elapsed.isFinite else { return }
        var received: Double = 0
        var sent: Double = 0
        for (name, current) in interfaces {
            guard let old = previous.interfaces[name] else { continue }
            // Reset/wrapped counters and newly connected interfaces establish
            // fresh baselines rather than causing negative rates or spikes.
            if current.received >= old.received {
                received += Double(current.received - old.received)
            }
            if current.sent >= old.sent {
                sent += Double(current.sent - old.sent)
            }
        }
        downloadBytesPerSecond = received / elapsed
        uploadBytesPerSecond = sent / elapsed
        append(downloadBytesPerSecond, to: &downloadHistory)
        append(uploadBytesPerSecond, to: &uploadHistory)
    }

    private func refreshStorage() {
        let fileManager = FileManager.default
        let volumes = [fileManager.homeDirectoryForCurrentUser, URL(fileURLWithPath: "/", isDirectory: true)]
        for url in volumes {
            if let values = try? url.resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey
            ]), let total = values.volumeTotalCapacity,
               let available = values.volumeAvailableCapacityForImportantUsage,
               total > 0, available >= 0 {
                storageTotalBytes = Double(total)
                storageUsedBytes = max(0, storageTotalBytes - Double(available))
                return
            }
            if let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path),
               let total = attributes[.systemSize] as? NSNumber,
               let available = attributes[.systemFreeSize] as? NSNumber,
               total.doubleValue > 0, available.doubleValue >= 0 {
                storageTotalBytes = total.doubleValue
                storageUsedBytes = max(0, storageTotalBytes - available.doubleValue)
                return
            }
        }
    }

    private func refreshPower() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        var fraction: Double?
        var charging = false
        var sourceName = "AC power"
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool != false else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? NSNumber,
               let maximum = description[kIOPSMaxCapacityKey] as? NSNumber,
               maximum.doubleValue > 0, current.doubleValue >= 0 {
                fraction = min(1, max(0, current.doubleValue / maximum.doubleValue))
            }
            charging = description[kIOPSIsChargingKey] as? Bool ?? false
            switch description[kIOPSPowerSourceStateKey] as? String {
            case kIOPSBatteryPowerValue: sourceName = "Battery power"
            case kIOPSACPowerValue: sourceName = "AC power"
            default: sourceName = "Unknown"
            }
            break
        }
        batteryFraction = fraction
        isCharging = charging
        powerSource = sourceName
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
    }

    nonisolated static func formatBytes(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = bytes
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        let number = String(format: unit == 0 || value >= 100 ? "%.0f" : "%.1f", value)
        return "\(number) \(units[unit])"
    }

    nonisolated static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return "—" }
        return "\(formatBytes(bytesPerSecond))/s"
    }
}
