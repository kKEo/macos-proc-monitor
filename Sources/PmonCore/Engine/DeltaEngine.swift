import Foundation

/// Per-interval changes of the system counters, in the units the database stores.
public struct SystemDelta: Equatable, Sendable {
    public var cpuUserMs: Int64 = 0, cpuSysMs: Int64 = 0, cpuIdleMs: Int64 = 0
    public var pBusyMs: Int64 = 0, eBusyMs: Int64 = 0
    public var faults: Int64 = 0, pageins: Int64 = 0, pageouts: Int64 = 0
    public var swapins: Int64 = 0, swapouts: Int64 = 0
    public var compressions: Int64 = 0, decompressions: Int64 = 0
    public var diskRead: Int64 = 0, diskWrite: Int64 = 0, diskOps: Int64 = 0, diskIoTimeMs: Int64 = 0
    public var netIn: Int64 = 0, netOut: Int64 = 0
}

/// Turns cumulative system readings into per-interval deltas.
///
/// Returns nil when there is no usable interval: the first reading, after `reset()`,
/// or when a counter went backwards (driver reload, interface removed). In every such case
/// the reading becomes the new baseline, so one interval is skipped rather than reported wrong.
public struct SystemDeltaEngine {
    private var prev: SystemReading?
    public init() {}

    /// Forget the baseline. Used when an interval spans sleep.
    public mutating func reset() { prev = nil }

    public mutating func delta(_ cur: SystemReading, coreIsPerformance: [Bool]) -> SystemDelta? {
        defer { prev = cur }
        guard let p = prev, p.cores.count == cur.cores.count else { return nil }
        var d = SystemDelta()

        // Tick counters are 32-bit and wrap; wrapping subtraction gives the right delta
        // as long as fewer than 2^32 ticks (about 497 days) passed in one interval.
        for (i, (a, b)) in zip(p.cores, cur.cores).enumerated() {
            let user = Int64(b.user &- a.user) + Int64(b.nice &- a.nice)
            let sys = Int64(b.sys &- a.sys)
            let idle = Int64(b.idle &- a.idle)
            d.cpuUserMs += user * 10; d.cpuSysMs += sys * 10; d.cpuIdleMs += idle * 10
            let isP = i < coreIsPerformance.count ? coreIsPerformance[i] : true
            if isP { d.pBusyMs += (user + sys) * 10 } else { d.eBusyMs += (user + sys) * 10 }
        }

        // 64-bit counters do not wrap in practice; a decrease means the source was reset.
        var reset = false
        func diff(_ a: UInt64, _ b: UInt64) -> Int64 {
            if b < a { reset = true; return 0 }
            return Int64(clamping: b - a)
        }
        d.faults = diff(p.vm.faults, cur.vm.faults)
        d.pageins = diff(p.vm.pageins, cur.vm.pageins)
        d.pageouts = diff(p.vm.pageouts, cur.vm.pageouts)
        d.swapins = diff(p.vm.swapins, cur.vm.swapins)
        d.swapouts = diff(p.vm.swapouts, cur.vm.swapouts)
        d.compressions = diff(p.vm.compressions, cur.vm.compressions)
        d.decompressions = diff(p.vm.decompressions, cur.vm.decompressions)
        d.diskRead = diff(p.disk.readBytes, cur.disk.readBytes)
        d.diskWrite = diff(p.disk.writeBytes, cur.disk.writeBytes)
        d.diskOps = diff(p.disk.readOps, cur.disk.readOps) + diff(p.disk.writeOps, cur.disk.writeOps)
        d.diskIoTimeMs = diff(p.disk.ioTimeNs, cur.disk.ioTimeNs) / 1_000_000
        d.netIn = diff(p.net.inBytes, cur.net.inBytes)
        d.netOut = diff(p.net.outBytes, cur.net.outBytes)
        return reset ? nil : d
    }
}
