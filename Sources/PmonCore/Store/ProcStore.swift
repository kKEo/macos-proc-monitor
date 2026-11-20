import Foundation

/// Why a process got a detail row in `proc_sample` (bit values of `proc_sample.reason`).
public struct SelectionReason: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let topCpu = SelectionReason(rawValue: 1)
    public static let topFootprint = SelectionReason(rawValue: 2)
    public static let floor = SelectionReason(rawValue: 4)
    /// The daemon itself: always stored, so its own cost is always visible.
    public static let selfProcess = SelectionReason(rawValue: 8)
}

/// Process and executable dimension rows, and the `proc_sample` fact rows.
/// Keeps in-memory id caches so steady-state sweeps do no lookups.
final class ProcStore {
    private let db: Database
    private let bootId: Int64
    private var exeIds: [String: Int64] = [:]
    /// Live process instances: kernel-unique id -> process row id.
    private(set) var procIds: [UInt64: Int64] = [:]
    private var uidByPid: [Int32: UInt64] = [:]
    private var unresolvedApp: Int64 = 0
    private var reconciled = false

    init(db: Database, bootId: Int64) throws {
        self.db = db
        self.bootId = bootId
        // Until the app resolver exists (phase 4) every process belongs to one placeholder app.
        try db.run("INSERT INTO app (key, name, kind) VALUES ('pmon.unresolved', 'Unresolved', 'system') ON CONFLICT(key) DO NOTHING")
        unresolvedApp = try db.scalarInt("SELECT app_id FROM app WHERE key = 'pmon.unresolved'") ?? 0
    }

    private func exeId(path: String, name: String) throws -> Int64 {
        if let id = exeIds[path] { return id }
        try db.run("INSERT INTO executable (path, name) VALUES (?, ?) ON CONFLICT(path) DO NOTHING", [path, name])
        let id = try db.scalarInt("SELECT exe_id FROM executable WHERE path = ?", [path]) ?? 0
        exeIds[path] = id
        return id
    }

    /// Create or refresh the rows for newly seen process instances.
    func apply(identities: [ProcIdentity], ts: Int64) throws {
        guard !identities.isEmpty else { return }
        for id in identities {
            let exe = try exeId(path: id.path, name: id.name)
            try db.run("""
                INSERT INTO process (boot_id, pid, start_ts, unique_id, source, exe_id, app_id, uid, translated, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(boot_id, pid, start_ts) DO UPDATE SET
                  last_seen = excluded.last_seen, unique_id = excluded.unique_id, source = excluded.source, exited_ts = NULL
                """, [bootId, id.pid, id.startTsMs, id.uid, id.own ? 0 : 1, exe, unresolvedApp, id.userId, id.translated, ts, ts])
            let procId = try db.scalarInt("SELECT proc_id FROM process WHERE boot_id = ? AND pid = ? AND start_ts = ?",
                                          [bootId, id.pid, id.startTsMs]) ?? 0
            procIds[id.uid] = procId
            uidByPid[id.pid] = id.uid
        }
        // Second pass: a parent or responsible process may appear later in the same batch.
        for id in identities {
            let parent = procIds[id.parentUid]
            let responsible = id.responsiblePid.flatMap { uidByPid[$0] }.flatMap { procIds[$0] }
            guard parent != nil || responsible != nil, let procId = procIds[id.uid] else { continue }
            try db.run("UPDATE process SET parent_proc_id = COALESCE(?, parent_proc_id), responsible_proc_id = COALESCE(?, responsible_proc_id) WHERE proc_id = ?",
                       [parent, responsible, procId])
        }
    }

    /// Close the rows of process instances that are no longer present.
    /// On the first call after start-up this also closes rows left open by a previous daemon run.
    func markExited(present: Set<UInt64>, ts: Int64) throws {
        if !reconciled {
            reconciled = true
            var stale: [Int64] = []
            try db.query("SELECT proc_id, unique_id FROM process WHERE boot_id = ? AND exited_ts IS NULL", [bootId]) { r in
                if !present.contains(UInt64(bitPattern: r.int(1))) { stale.append(r.int(0)) }
            }
            for id in stale { try db.run("UPDATE process SET exited_ts = ? WHERE proc_id = ?", [ts, id]) }
        }
        for (uid, procId) in procIds where !present.contains(uid) {
            try db.run("UPDATE process SET exited_ts = ?, last_seen = ? WHERE proc_id = ?", [ts, ts, procId])
            procIds[uid] = nil
        }
        if uidByPid.count > present.count * 2 + 64 {       // drop pids of long-gone processes
            uidByPid = uidByPid.filter { present.contains($0.value) }
        }
    }

    /// Refresh `last_seen` of every live process in one statement.
    func touchLive(ts: Int64) throws {
        try db.run("UPDATE process SET last_seen = ? WHERE boot_id = ? AND exited_ts IS NULL", [ts, bootId])
    }

    func insertSample(sampleId: Int64, _ d: ProcDelta, reason: SelectionReason) throws {
        guard let procId = procIds[d.uid] else { return }      // identity not stored (exited mid-sweep)
        try db.run("""
            INSERT OR REPLACE INTO proc_sample (sample_id, proc_id, cpu_user_ms, cpu_sys_ms, cpu_p_ms, cpu_fg_ms, cpu_util_ms, cpu_bg_ms,
              runnable_ms, footprint, rss, d_footprint, d_pageins, d_disk_read, d_disk_write, d_wakeups, d_csw,
              d_energy_uj, d_instructions, threads, fidelity, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?)
            """, [sampleId, procId, d.cpuUserMs, d.cpuSysMs, d.cpuPMs, d.cpuFgMs, d.cpuUtilMs, d.cpuBgMs,
                  d.waitMs, d.footprint, d.rss, d.dFootprint, d.dPageins, d.dDiskRead, d.dDiskWrite, d.dWakeups, d.dCsw,
                  d.dEnergyUj, d.dInstructions, d.threads, reason.rawValue])
    }
}

/// Decides which processes get a detail row. Provisional: phase 4 replaces this with the
/// full top-K-per-dimension rule once app-level rows carry the complete totals.
enum ProvisionalSelection {
    static let cpuFloorMs: Int64 = 20
    static let footprintDeltaFloor: Int64 = 4 << 20
    static let diskFloor: Int64 = 256 << 10
    static let topK = 5

    static func select(_ deltas: [ProcDelta], selfPid: Int32?) -> [(ProcDelta, SelectionReason)] {
        var reasons: [UInt64: SelectionReason] = [:]
        for d in deltas.sorted(by: { $0.cpuNs > $1.cpuNs }).prefix(topK) where d.cpuNs > 0 { reasons[d.uid, default: []].insert(.topCpu) }
        for d in deltas.sorted(by: { $0.footprint > $1.footprint }).prefix(topK) { reasons[d.uid, default: []].insert(.topFootprint) }
        for d in deltas {
            if d.cpuMs >= cpuFloorMs || abs(d.dFootprint) >= footprintDeltaFloor || d.dDiskRead + d.dDiskWrite >= diskFloor {
                reasons[d.uid, default: []].insert(.floor)
            }
            if d.pid == selfPid { reasons[d.uid, default: []].insert(.selfProcess) }
        }
        return deltas.compactMap { d in reasons[d.uid].map { (d, $0) } }
    }
}
