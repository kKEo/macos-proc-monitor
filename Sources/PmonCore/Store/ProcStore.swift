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
    /// CPU columns of this (foreign) row come from `ps` and cover `proc_dt_ms`.
    public static let cpuFromPs = SelectionReason(rawValue: 16)
    public static let topGrowth = SelectionReason(rawValue: 32)
    public static let topDisk = SelectionReason(rawValue: 64)
    public static let topWakeups = SelectionReason(rawValue: 128)
    public static let topPageins = SelectionReason(rawValue: 256)
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
    private var reconciled = false
    private var resolver = AppResolver()
    private var appIds: [String: Int64] = [:]
    /// Live process instances: kernel-unique id -> app row id.
    private(set) var appIdByUid: [UInt64: Int64] = [:]
    private(set) var uidByPidLive: [Int32: UInt64] = [:]
    /// Rows of the synthetic apps that make totals reconcile.
    private(set) var foreignResidualApp: Int64 = 0, unattributedApp: Int64 = 0, otherApp: Int64 = 0
    /// Processes that are an app's own main process (attributed by their bundle), for launch and quit events.
    private(set) var appMainProcs: [UInt64: Int64] = [:]

    init(db: Database, bootId: Int64) throws {
        self.db = db
        self.bootId = bootId
        // Synthetic apps: what cannot be pinned on a real one still has to land somewhere, so that
        // app-level totals always add up to the system totals.
        foreignResidualApp = try appId(AppRef(key: "system.foreign", name: "System processes (combined)", kind: "system", bundlePath: nil, inheritable: false), ts: nil)
        unattributedApp = try appId(AppRef(key: "system.unattributed", name: "Kernel and short-lived processes", kind: "system", bundlePath: nil, inheritable: false), ts: nil)
        otherApp = try appId(AppRef(key: "pmon.other", name: "Idle apps (combined)", kind: "system", bundlePath: nil, inheritable: false), ts: nil)
    }

    func appId(_ app: AppRef, ts: Int64?) throws -> Int64 {
        if let id = appIds[app.key] { return id }
        try db.run("""
            INSERT INTO app (key, name, kind, bundle_path, first_seen, last_seen) VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET name = excluded.name, kind = excluded.kind, bundle_path = excluded.bundle_path,
              last_seen = COALESCE(excluded.last_seen, last_seen)
            """, [app.key, app.name, app.kind, app.bundlePath, ts, ts])
        let id = try db.scalarInt("SELECT app_id FROM app WHERE key = ?", [app.key]) ?? 0
        appIds[app.key] = id
        return id
    }

    private func exeId(path: String, name: String) throws -> Int64 {
        if let id = exeIds[path] { return id }
        try db.run("INSERT INTO executable (path, name) VALUES (?, ?) ON CONFLICT(path) DO NOTHING", [path, name])
        let id = try db.scalarInt("SELECT exe_id FROM executable WHERE path = ?", [path]) ?? 0
        exeIds[path] = id
        return id
    }

    /// Create or refresh the rows for newly seen process instances, attributing each to an app.
    /// Returns the instances that are an app's main process and were not known before.
    @discardableResult
    func apply(identities: [ProcIdentity], ts: Int64) throws -> [(uid: UInt64, procId: Int64, appId: Int64)] {
        guard !identities.isEmpty else { return [] }
        let attribution = resolver.resolve(identities)
        var newMains: [(uid: UInt64, procId: Int64, appId: Int64)] = []
        for id in identities {
            let exe = try exeId(path: id.path, name: id.name)
            let (app, rule) = attribution[id.uid]!
            let app_id = try appId(app, ts: ts)
            try db.run("""
                INSERT INTO process (boot_id, pid, start_ts, unique_id, source, exe_id, app_id, uid, translated, attribution, first_seen, last_seen)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(boot_id, pid, start_ts) DO UPDATE SET
                  last_seen = excluded.last_seen, unique_id = excluded.unique_id, source = excluded.source,
                  app_id = excluded.app_id, attribution = excluded.attribution, exited_ts = NULL
                """, [bootId, id.pid, id.startTsMs, id.uid, id.own ? 0 : 1, exe, app_id, id.userId, id.translated, rule.rawValue, ts, ts])
            let procId = try db.scalarInt("SELECT proc_id FROM process WHERE boot_id = ? AND pid = ? AND start_ts = ?",
                                          [bootId, id.pid, id.startTsMs]) ?? 0
            procIds[id.uid] = procId
            uidByPid[id.pid] = id.uid
            uidByPidLive[id.pid] = id.uid
            appIdByUid[id.uid] = app_id
            // An app's main process: attributed by its own bundle, and not a helper of something else.
            // Helpers, extensions and XPC services live deeper inside the bundle; only an executable
            // directly in Contents/MacOS is the app itself.
            let macOSDir = (app.bundlePath ?? "") + "/Contents/MacOS/"
            let isMainExecutable = app.bundlePath != nil && id.path.hasPrefix(macOSDir) && !id.path.dropFirst(macOSDir.count).contains("/")
            if rule == .bundle, isMainExecutable, id.responsiblePid == nil || id.responsiblePid == id.pid, id.ppid <= 1, appMainProcs[id.uid] == nil {
                appMainProcs[id.uid] = app_id
                newMains.append((id.uid, procId, app_id))
            }
        }
        // Second pass: a parent or responsible process may appear later in the same batch.
        for id in identities {
            let parent = procIds[id.parentUid]
            let responsible = id.responsiblePid.flatMap { uidByPid[$0] }.flatMap { procIds[$0] }
            guard parent != nil || responsible != nil, let procId = procIds[id.uid] else { continue }
            try db.run("UPDATE process SET parent_proc_id = COALESCE(?, parent_proc_id), responsible_proc_id = COALESCE(?, responsible_proc_id) WHERE proc_id = ?",
                       [parent, responsible, procId])
        }
        return newMains
    }

    /// Close the rows of process instances that are no longer present.
    /// On the first call after start-up this also closes rows left open by a previous daemon run.
    /// Returns the app main processes that went away (for quit events).
    @discardableResult
    func markExited(present: Set<UInt64>, ts: Int64) throws -> [(procId: Int64, appId: Int64)] {
        if !reconciled {
            reconciled = true
            var stale: [Int64] = []
            try db.query("SELECT proc_id, unique_id FROM process WHERE boot_id = ? AND exited_ts IS NULL", [bootId]) { r in
                if !present.contains(UInt64(bitPattern: r.int(1))) { stale.append(r.int(0)) }
            }
            for id in stale { try db.run("UPDATE process SET exited_ts = ? WHERE proc_id = ?", [ts, id]) }
        }
        var quitMains: [(procId: Int64, appId: Int64)] = []
        for (uid, procId) in procIds where !present.contains(uid) {
            try db.run("UPDATE process SET exited_ts = ?, last_seen = ? WHERE proc_id = ?", [ts, ts, procId])
            procIds[uid] = nil
            appIdByUid[uid] = nil
            if let app = appMainProcs.removeValue(forKey: uid) { quitMains.append((procId, app)) }
        }
        if uidByPid.count > present.count * 2 + 64 {       // drop pids of long-gone processes
            uidByPid = uidByPid.filter { present.contains($0.value) }
            uidByPidLive = uidByPidLive.filter { present.contains($0.value) }
        }
        resolver.retain(present: present)
        return quitMains.sorted { $0.procId < $1.procId }
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

extension ProcStore {
    /// The app and most recent process of an executable, by path or else by name. Used to attach
    /// system diagnostic reports to an app.
    func lookup(exePath: String?, name: String?) throws -> (appId: Int64, procId: Int64)? {
        var hit: (Int64, Int64)?
        if let exePath {
            try db.query("SELECT p.app_id, p.proc_id FROM process p JOIN executable e USING (exe_id) WHERE e.path = ? ORDER BY p.proc_id DESC LIMIT 1", [exePath]) {
                hit = ($0.int(0), $0.int(1))
            }
        }
        if hit == nil, let name {
            try db.query("SELECT p.app_id, p.proc_id FROM process p JOIN executable e USING (exe_id) WHERE e.name = ? ORDER BY p.proc_id DESC LIMIT 1", [name]) {
                hit = ($0.int(0), $0.int(1))
            }
        }
        return hit.map { (appId: $0.0, procId: $0.1) }
    }

    /// A row for a process read through `top` or `ps`. Columns the source lacks stay NULL.
    func insertForeign(sampleId: Int64, _ d: ForeignDelta, reason: SelectionReason) throws {
        guard let procId = procIds[d.uid] else { return }
        var reason = reason
        if d.cpuFromPs { reason.insert(.cpuFromPs) }
        try db.run("""
            INSERT OR REPLACE INTO proc_sample (sample_id, proc_id, cpu_user_ms, cpu_sys_ms, footprint, mem_compressed, d_footprint,
              d_pageins, d_wakeups, d_csw, d_instructions, threads, fidelity, reason)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [sampleId, procId, d.cpuUserMs, d.cpuSysMs, d.footprint, d.compressed, d.dFootprint,
                  d.dPageins, d.dWakeups, d.dCsw, d.dInstructions, d.threads, d.fidelity, reason.rawValue])
    }
}
