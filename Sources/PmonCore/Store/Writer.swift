import Foundation

/// Bit values of `sample.flags`.
public struct SampleFlags: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let afterWake = SampleFlags(rawValue: 1)
    public static let degraded = SampleFlags(rawValue: 2)
    public static let helperPresent = SampleFlags(rawValue: 4)
    public static let foreignFresh = SampleFlags(rawValue: 8)
    public static let episodeOpen = SampleFlags(rawValue: 16)
    /// Foreign CPU on this tick comes from `ps` and covers `proc_dt_ms` instead of `foreign_dt_ms`.
    public static let foreignCpuFromPs = SampleFlags(rawValue: 32)
}

/// Dimension rows for the machine and the current boot.
enum Dimensions {
    static func upsertHost(_ db: Database, _ h: HostInfo) throws {
        try db.run("""
            INSERT INTO host (host_id, model, chip, p_cores, e_cores, mem_bytes, page_size, timebase_num, timebase_den)
            VALUES (1, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(host_id) DO UPDATE SET model=excluded.model, chip=excluded.chip, p_cores=excluded.p_cores,
              e_cores=excluded.e_cores, mem_bytes=excluded.mem_bytes, page_size=excluded.page_size,
              timebase_num=excluded.timebase_num, timebase_den=excluded.timebase_den
            """, [h.model, h.chip, h.pCores, h.eCores, h.memBytes, h.pageSize, h.timebaseNum, h.timebaseDen])
    }

    static func bootId(_ db: Database, _ h: HostInfo) throws -> Int64 {
        try db.run("""
            INSERT INTO boot (session_uuid, boot_ts, os_version, os_build) VALUES (?, ?, ?, ?)
            ON CONFLICT(session_uuid) DO NOTHING
            """, [h.bootSessionUUID, h.bootTsMs, h.osVersion, h.osBuild])
        return try db.scalarInt("SELECT boot_id FROM boot WHERE session_uuid = ?", [h.bootSessionUUID]) ?? 0
    }
}

/// Totals over one process sweep, stored on the system sample of the same tick.
struct ProcTotals {
    var procCount: Int
    /// Threads of the processes we can read; foreign processes are not included yet.
    var threadCount: Int
    var waitMs: Int64
    /// System busy CPU not accounted for by any process we read. Nil when the system
    /// counters did not cover the whole process interval.
    var unattributedCpuMs: Int64?
    /// Device bytes not accounted for by readable processes (other users' processes, the kernel,
    /// swap). Approximate: device and per-process counters are not measured the same way.
    var unattributedDiskBytes: Int64?
    /// CPU measured for other users' processes, and what is left after them: kernel work and
    /// processes that lived and died between sweeps. Signed, so over-attribution is visible.
    var foreignCpuMs: Int64?
    var unknownCpuMs: Int64?
}

/// Writes one tick's results in a single transaction.
struct Writer {
    let db: Database
    let bootId: Int64
    let pageSize: Int64

    /// Insert the `sample` row and return its id.
    func insertSample(tick: Tick, tier: Int, flags: SampleFlags, procDtMs: Int64? = nil, foreignDtMs: Int64? = nil) throws -> Int64 {
        try db.run("INSERT INTO sample (ts, boot_id, dt_ms, proc_dt_ms, foreign_dt_ms, tier, flags) VALUES (?, ?, ?, ?, ?, ?, ?)",
                   [tick.wallMs, bootId, Int64(tick.dtNs / 1_000_000), procDtMs, foreignDtMs, tier, flags.rawValue])
        return db.lastInsertRowId
    }

    func insertEvent(ts: Int64, kind: String, value: Int64?, detail: String?) throws {
        try db.run("INSERT INTO event (ts, kind, value, detail) VALUES (?, ?, ?, ?)", [ts, kind, value, detail])
    }

    func insertSystem(sampleId: Int64, tick: Tick, reading r: SystemReading, delta d: SystemDelta, slow: SlowReading?,
                      procs: ProcTotals?) throws {
        let cols: [(String, Any?)] = [
            ("proc_count", procs?.procCount), ("thread_count", procs?.threadCount),
            ("runnable_wait_ms", procs?.waitMs), ("unattributed_cpu_ms", procs?.unattributedCpuMs),
            ("unattributed_disk_bytes", procs?.unattributedDiskBytes),
            ("foreign_cpu_ms", procs?.foreignCpuMs), ("unknown_cpu_ms", procs?.unknownCpuMs),
            ("sample_id", sampleId),
            ("cpu_user_ms", d.cpuUserMs), ("cpu_sys_ms", d.cpuSysMs), ("cpu_idle_ms", d.cpuIdleMs),
            ("p_busy_ms", d.pBusyMs), ("e_busy_ms", d.eBusyMs),
            ("load1", r.load1), ("canary_late_ms", Double(tick.lateNs) / 1e6),
            ("mem_free", Int64(r.vm.freePages) * pageSize), ("mem_active", Int64(r.vm.activePages) * pageSize),
            ("mem_inactive", Int64(r.vm.inactivePages) * pageSize), ("mem_wired", Int64(r.vm.wiredPages) * pageSize),
            ("mem_compressed", Int64(r.vm.compressedPages) * pageSize),
            ("compressor_size", Int64(r.vm.compressorPages) * pageSize),
            ("swap_used", r.swapUsed), ("swap_total", r.swapTotal),
            ("pressure_level", r.pressureLevel), ("mem_level_pct", r.memLevelPct),
            ("d_pageins", d.pageins), ("d_pageouts", d.pageouts), ("d_swapins", d.swapins), ("d_swapouts", d.swapouts),
            ("d_compressions", d.compressions), ("d_decompressions", d.decompressions), ("d_faults", d.faults),
            ("d_disk_read", d.diskRead), ("d_disk_write", d.diskWrite), ("d_disk_ops", d.diskOps),
            ("disk_io_time_ms", d.diskIoTimeMs),
            ("d_net_in", d.netIn), ("d_net_out", d.netOut),
            ("thermal_level", slow?.thermalLevel), ("on_battery", slow?.onBattery),
            ("low_power", slow?.lowPower), ("battery_pct", slow?.batteryPct),
        ]
        let sql = "INSERT INTO sys_sample (\(cols.map { $0.0 }.joined(separator: ", "))) VALUES (\(cols.map { _ in "?" }.joined(separator: ", ")))"
        try db.run(sql, cols.map { $0.1 })
    }

    func insertVolumes(sampleId: Int64, _ volumes: [VolumeReading]) throws {
        for v in volumes {
            try db.run("INSERT OR REPLACE INTO volume_sample (sample_id, mount, total, free) VALUES (?, ?, ?, ?)",
                       [sampleId, v.mount, v.total, v.free])
        }
    }
}
