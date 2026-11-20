import Foundation

/// Per-interval activity of one process, in the units the database stores.
public struct ProcDelta: Equatable, Sendable {
    public var uid: UInt64 = 0
    public var pid: Int32 = 0
    /// Exact CPU time in the interval; the millisecond fields below are rounded from parts of it.
    public var cpuNs: UInt64 = 0
    public var cpuUserMs: Int64 = 0, cpuSysMs: Int64 = 0, cpuPMs: Int64 = 0
    public var cpuFgMs: Int64 = 0, cpuUtilMs: Int64 = 0, cpuBgMs: Int64 = 0
    /// Time threads were ready to run but had no core.
    public var waitMs: Int64 = 0
    public var footprint: Int64 = 0, rss: Int64 = 0
    public var dFootprint: Int64 = 0
    public var dPageins: Int64 = 0, dDiskRead: Int64 = 0, dDiskWrite: Int64 = 0
    public var dWakeups: Int64 = 0, dCsw: Int64 = 0, dEnergyUj: Int64 = 0, dInstructions: Int64 = 0
    public var threads: Int = 0
    /// The process started during this interval, so the delta is its whole life so far.
    public var born = false

    public var cpuMs: Int64 { cpuUserMs + cpuSysMs }
}

/// Turns cumulative per-process readings into per-interval deltas, keyed by process instance.
///
/// A process seen for the first time contributes its lifetime counters only if it was born
/// after the previous sweep; otherwise (the daemon just started) it is only a baseline.
/// Pid reuse is harmless because the key is the kernel-unique id, not the pid.
public struct ProcDeltaEngine {
    private var prev: [UInt64: ProcReading] = [:]
    private var prevMonoNs: UInt64?

    public init() {}

    /// Forget all baselines. Used when an interval spans sleep.
    public mutating func reset() { prev.removeAll(); prevMonoNs = nil }

    /// Returns the deltas of this sweep and the unique ids of readable processes that disappeared.
    public mutating func deltas(_ procs: [ProcReading], monoNs: UInt64) -> (deltas: [ProcDelta], exited: [UInt64]) {
        var out: [ProcDelta] = []
        out.reserveCapacity(procs.count)
        var current: [UInt64: ProcReading] = [:]
        current.reserveCapacity(procs.count)

        for r in procs {
            current[r.uid] = r
            if let p = prev[r.uid] {
                if let d = Self.diff(from: p, to: r, born: false) { out.append(d) }
            } else if let last = prevMonoNs, r.startNs > last {
                out.append(Self.diff(from: ProcReading(), to: r, born: true)!)
            }
        }
        let exited = prev.keys.filter { current[$0] == nil }
        prev = current
        prevMonoNs = monoNs
        return (out, exited)
    }

    /// Nil when a cumulative counter went backwards: the reading is then only a new baseline.
    static func diff(from p: ProcReading, to r: ProcReading, born: Bool) -> ProcDelta? {
        guard r.userNs >= p.userNs, r.sysNs >= p.sysNs, r.runnableNs >= p.runnableNs,
              r.diskRead >= p.diskRead, r.diskWrite >= p.diskWrite, r.pageins >= p.pageins,
              r.energyNj >= p.energyNj, r.idleWakeups >= p.idleWakeups, r.instructions >= p.instructions else { return nil }
        func ms(_ ns: UInt64) -> Int64 { Int64((ns + 500_000) / 1_000_000) }
        func sub(_ a: UInt64, _ b: UInt64) -> UInt64 { a >= b ? a - b : 0 }
        var d = ProcDelta()
        d.uid = r.uid; d.pid = r.pid; d.born = born
        d.cpuNs = (r.userNs - p.userNs) + (r.sysNs - p.sysNs)
        d.cpuUserMs = ms(r.userNs - p.userNs); d.cpuSysMs = ms(r.sysNs - p.sysNs)
        d.cpuPMs = ms(sub(r.pNs, p.pNs))
        d.cpuFgMs = ms(sub(r.fgNs, p.fgNs)); d.cpuUtilMs = ms(sub(r.utilNs, p.utilNs)); d.cpuBgMs = ms(sub(r.bgNs, p.bgNs))
        // The kernel counter includes time on a core (phase 0 finding), so subtract CPU time.
        d.waitMs = ms(sub(r.runnableNs - p.runnableNs, d.cpuNs))
        d.footprint = Int64(clamping: r.footprint); d.rss = Int64(clamping: r.rss)
        d.dFootprint = Int64(clamping: r.footprint) - Int64(clamping: p.footprint)
        d.dPageins = Int64(r.pageins - p.pageins)
        d.dDiskRead = Int64(clamping: r.diskRead - p.diskRead); d.dDiskWrite = Int64(clamping: r.diskWrite - p.diskWrite)
        d.dWakeups = Int64(clamping: r.idleWakeups - p.idleWakeups)
        d.dCsw = Int64(r.csw &- p.csw)                    // 32-bit counter: wrapping subtraction
        d.dEnergyUj = Int64(clamping: (r.energyNj - p.energyNj) / 1000)
        d.dInstructions = Int64(clamping: r.instructions - p.instructions)
        d.threads = Int(r.threads)
        return d
    }
}
