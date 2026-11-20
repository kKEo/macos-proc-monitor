import Foundation

/// Decides which processes get a detail row in `proc_sample`.
///
/// App-level rows (`app_sample`) carry the complete totals, so process rows only need to exist
/// where they are interesting: the top few in each dimension, plus anything above a floor.
public struct Selection: Sendable {
    public var topK = 5
    /// Share of one core.
    public var cpuFloor = 0.02
    public var footprintFloor: Int64 = 200 << 20
    public var growthFloor: Int64 = 20 << 20
    public var diskFloor: Int64 = 5 << 20

    public init() {}

    struct Candidate {
        var uid: UInt64
        var cpuNs: UInt64 = 0
        var footprint: Int64 = 0, growth: Int64 = 0, disk: Int64 = 0, wakeups: Int64 = 0, pageins: Int64 = 0
        var isSelf = false
    }

    /// Reasons per selected process. `dtMs` is the interval the CPU figures cover.
    func select(_ candidates: [Candidate], dtMs: Int64) -> [UInt64: SelectionReason] {
        var reasons: [UInt64: SelectionReason] = [:]
        func top(_ reason: SelectionReason, _ value: (Candidate) -> Int64) {
            for c in candidates.filter({ value($0) > 0 }).sorted(by: { value($0) > value($1) }).prefix(topK) {
                reasons[c.uid, default: []].insert(reason)
            }
        }
        top(.topCpu) { Int64(clamping: $0.cpuNs) }
        top(.topFootprint) { $0.footprint }
        top(.topGrowth) { $0.growth }
        top(.topDisk) { $0.disk }
        top(.topWakeups) { $0.wakeups }
        top(.topPageins) { $0.pageins }
        let cpuFloorNs = UInt64(Double(max(dtMs, 1)) * 1e6 * cpuFloor)
        for c in candidates {
            if c.cpuNs >= cpuFloorNs || c.footprint >= footprintFloor || c.growth >= growthFloor || c.disk >= diskFloor {
                reasons[c.uid, default: []].insert(.floor)
            }
            if c.isSelf { reasons[c.uid, default: []].insert(.selfProcess) }
        }
        return reasons
    }

    func select(own deltas: [ProcDelta], selfPid: Int32?, dtMs: Int64) -> [(ProcDelta, SelectionReason)] {
        let reasons = select(deltas.map {
            Candidate(uid: $0.uid, cpuNs: $0.cpuNs, footprint: $0.footprint, growth: $0.dFootprint,
                      disk: $0.dDiskRead + $0.dDiskWrite, wakeups: $0.dWakeups, pageins: $0.dPageins, isSelf: $0.pid == selfPid)
        }, dtMs: dtMs)
        return deltas.compactMap { d in reasons[d.uid].map { (d, $0) } }
    }

    func select(foreign deltas: [ForeignDelta], dtMs: Int64) -> [(ForeignDelta, SelectionReason)] {
        let reasons = select(deltas.map {
            Candidate(uid: $0.uid, cpuNs: $0.cpuNs, footprint: $0.footprint ?? 0, growth: $0.dFootprint ?? 0,
                      disk: 0, wakeups: $0.dWakeups ?? 0, pageins: $0.dPageins ?? 0)
        }, dtMs: dtMs)
        return deltas.compactMap { d in reasons[d.uid].map { (d, $0) } }
    }
}
