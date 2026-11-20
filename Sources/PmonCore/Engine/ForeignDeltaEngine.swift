import Foundation

/// Per-interval activity of a process we cannot read natively. Fields a source cannot supply
/// are nil and are stored as NULL, never as zero.
public struct ForeignDelta: Equatable, Sendable {
    public var uid: UInt64 = 0
    public var pid: Int32 = 0
    /// Total CPU in the interval, for totals and ranking (0 when the source gave none).
    public var cpuNs: UInt64 = 0
    public var cpuUserMs: Int64?, cpuSysMs: Int64?
    public var footprint: Int64?, compressed: Int64?, dFootprint: Int64?
    public var dPageins: Int64?, dCsw: Int64?, dWakeups: Int64?, dInstructions: Int64?
    public var threads: Int?
    /// 1 = top stream, 2 = ps (CPU only).
    public var fidelity = 1
    /// CPU columns come from `ps` and cover the process interval, not the top interval.
    public var cpuFromPs = false
}

/// Deltas between consecutive `top` samples, keyed by process instance.
/// A process first seen in a sample is a baseline only.
public struct TopDeltaEngine {
    private var prev: [UInt64: TopRow] = [:]
    private var prevMonoNs: UInt64?
    public init() {}

    public mutating func reset() { prev.removeAll(); prevMonoNs = nil }

    /// Nil for the first sample (baseline). `uidByPid` maps the pids of foreign processes
    /// present in the current sweep to their unique ids; rows for other pids are ignored.
    public mutating func deltas(_ sample: TopSample, uidByPid: [Int32: UInt64]) -> (dtMs: Int64, rows: [UInt64: ForeignDelta])? {
        var current: [UInt64: TopRow] = [:]
        var out: [UInt64: ForeignDelta] = [:]
        for row in sample.rows {
            guard let uid = uidByPid[row.pid] else { continue }
            current[uid] = row
            guard let p = prev[uid], row.cpuNs >= p.cpuNs, row.pageins >= p.pageins, row.idlew >= p.idlew else { continue }
            var d = ForeignDelta()
            d.uid = uid; d.pid = row.pid; d.fidelity = 1
            d.cpuNs = row.cpuNs - p.cpuNs
            // top reports only total CPU; it is stored as user time with system time 0.
            d.cpuUserMs = Int64((d.cpuNs + 500_000) / 1_000_000); d.cpuSysMs = 0
            d.footprint = Int64(clamping: row.mem); d.compressed = Int64(clamping: row.cmprs)
            d.dFootprint = Int64(clamping: row.mem) - Int64(clamping: p.mem)
            d.dPageins = Int64(clamping: row.pageins - p.pageins)
            d.dCsw = row.csw >= p.csw ? Int64(clamping: row.csw - p.csw) : nil
            d.dWakeups = Int64(clamping: row.idlew - p.idlew)
            d.dInstructions = Int64(clamping: row.instrs)        // already a per-interval value
            d.threads = Int(row.threads)
            out[uid] = d
        }
        defer { prev = current; prevMonoNs = sample.monoNs }
        guard let last = prevMonoNs, sample.monoNs > last else { return nil }
        return (Int64((sample.monoNs - last) / 1_000_000), out)
    }
}

/// Deltas between consecutive `ps` samples: CPU time only, split into user and system.
public struct PsDeltaEngine {
    private var prev: [UInt64: PsRow] = [:]
    private var hasBaseline = false
    public init() {}

    public mutating func reset() { prev.removeAll(); hasBaseline = false }

    /// Nil for the first sample after a reset (baseline).
    public mutating func deltas(_ sample: PsSample, uidByPid: [Int32: UInt64]) -> [UInt64: (userMs: Int64, sysMs: Int64, ns: UInt64)]? {
        var current: [UInt64: PsRow] = [:]
        var out: [UInt64: (userMs: Int64, sysMs: Int64, ns: UInt64)] = [:]
        for row in sample.rows {
            guard let uid = uidByPid[row.pid] else { continue }
            current[uid] = row
            guard let p = prev[uid], row.userNs >= p.userNs, row.sysNs >= p.sysNs else { continue }
            let u = row.userNs - p.userNs, s = row.sysNs - p.sysNs
            out[uid] = (Int64((u + 500_000) / 1_000_000), Int64((s + 500_000) / 1_000_000), u + s)
        }
        defer { prev = current; hasBaseline = true }
        return hasBaseline ? out : nil
    }
}

/// A short history of a cumulative quantity, for reading its value at an arbitrary past time.
/// Used to line up system-wide counters (sampled on ticks) with a `top` sample (which arrives
/// between ticks).
struct CumulativeSeries {
    private var points: [(t: UInt64, v: Double)] = []
    private(set) var total = 0.0

    mutating func reset() { points.removeAll(); total = 0 }

    mutating func add(_ delta: Double, at t: UInt64) {
        total += delta
        points.append((t, total))
        if points.count > 64 { points.removeFirst(points.count - 64) }
    }

    /// Start the series at `t` without adding anything (the first reading is only a baseline).
    mutating func anchor(at t: UInt64) { if points.isEmpty { points.append((t, total)) } }

    /// Linearly interpolated value at `t`; nil when `t` lies outside the recorded range.
    func value(at t: UInt64) -> Double? {
        guard let first = points.first, let last = points.last, t >= first.t, t <= last.t else { return nil }
        for i in 1..<max(points.count, 1) where points[i].t >= t {
            let a = points[i - 1], b = points[i]
            if b.t == a.t { return b.v }
            return a.v + (b.v - a.v) * Double(t - a.t) / Double(b.t - a.t)
        }
        return last.v
    }
}
