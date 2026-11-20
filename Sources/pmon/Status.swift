import ArgumentParser
import Foundation
import PmonCore

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the current machine condition and daemon health.")

    @Option(help: "Database file.")
    var db: String = PmonPaths.database

    func run() throws {
        guard FileManager.default.fileExists(atPath: db) else {
            print("No database at \(db). Start the daemon with `pmon install`.")
            throw ExitCode(1)
        }
        let database = try Database(path: db, readOnly: true)

        var pCores = 4.0, eCores = 4.0
        try database.query("SELECT model, chip, p_cores, e_cores, mem_bytes FROM host WHERE host_id = 1") { r in
            pCores = Double(r.int(2)); eCores = Double(r.int(3))
            print("pmon \(PmonVersion.string) — \(r.text(0)), \(r.text(1)) (\(r.int(2))P+\(r.int(3))E), \(r.int(4) >> 30) GB")
        }

        // Daemon health: the lock file holds the pid; launchd knows whether the agent is loaded.
        var daemon = "not running"
        if let text = try? String(contentsOfFile: PmonPaths.lock(forDatabase: db), encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), kill(pid, 0) == 0 {
            daemon = "running (pid \(pid))"
        }
        line("daemon", "\(daemon), launchd agent \(agentLoaded() ? "loaded" : "not loaded")")

        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var found = false
        try database.query("""
            SELECT s.ts, s.dt_ms, y.cpu_user_ms, y.cpu_sys_ms, y.cpu_idle_ms, y.p_busy_ms, y.e_busy_ms, y.load1,
                   y.canary_late_ms, y.mem_level_pct, y.pressure_level, y.mem_free, y.mem_compressed, y.compressor_size,
                   y.swap_used, y.d_disk_read, y.d_disk_write, y.disk_io_time_ms, y.d_net_in, y.d_net_out,
                   y.on_battery, y.battery_pct, y.thermal_level, y.low_power, y.d_swapouts, y.d_decompressions
            FROM sample s JOIN sys_sample y USING (sample_id) ORDER BY s.sample_id DESC LIMIT 1
            """) { r in
            found = true
            let dt = max(Double(r.int(1)) / 1000, 0.001)
            let busy = Double(r.int(2) + r.int(3)), total = busy + Double(r.int(4))
            line("last sample", "\(fmt(Double(now - r.int(0)) / 1000, 0)) s ago (interval \(fmt(dt, 1)) s)")
            line("cpu", "\(pct(busy, total)) busy (P \(pct(Double(r.int(5)), dt * 1000 * pCores)), E \(pct(Double(r.int(6)), dt * 1000 * eCores)))"
                 + "   load \(fmt(r.double(7), 2))   timer lateness \(fmt(r.double(8), 2)) ms")
            let pressure = [1: "normal", 2: "warn", 4: "critical"][Int(r.int(10))] ?? "level \(r.int(10))"
            line("memory", "level \(r.int(9)) %, pressure \(pressure), free \(bytes(r.int(11))), compressed \(bytes(r.int(12))) held in \(bytes(r.int(13))), swap \(bytes(r.int(14)))")
            line("paging", "\(fmt(Double(r.int(24)) / dt, 0)) swap-outs/s, \(fmt(Double(r.int(25)) / dt, 0)) decompressions/s")
            line("disk", "read \(bytes(Int64(Double(r.int(15)) / dt)))/s, write \(bytes(Int64(Double(r.int(16)) / dt)))/s, queue depth \(fmt(Double(r.int(17)) / 1000 / dt, 2))")
            line("network", "in \(bytes(Int64(Double(r.int(18)) / dt)))/s, out \(bytes(Int64(Double(r.int(19)) / dt)))/s")
            if !r.isNull(20) {
                let thermal = ["nominal", "fair", "serious", "critical"][min(Int(r.int(22)), 3)]
                line("power", "\(r.int(20) == 1 ? "battery" : "AC")\(r.isNull(21) ? "" : ", battery \(r.int(21)) %"), thermal \(thermal)\(r.int(23) == 1 ? ", Low Power Mode" : "")")
            }
        }
        if !found { line("last sample", "none yet — the first sample appears two intervals after the daemon starts") }

        try processSection(database, now: now)

        let lastHour = try database.scalarInt("SELECT COUNT(*) FROM sample WHERE ts >= ?", [now - 3_600_000]) ?? 0
        let totalSamples = try database.scalarInt("SELECT COUNT(*) FROM sample") ?? 0
        let wakes = try database.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 1") ?? 0
        // Recent rows live in the write-ahead log until SQLite checkpoints them, so count both files.
        let size = [db, db + "-wal"].reduce(Int64(0)) { sum, path in
            sum + (((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        line("history", "\(lastHour) samples in the last hour, \(totalSamples) in total, \(wakes) wake-ups recorded, database \(bytes(size))")
    }

    /// Process counts, the monitor's own cost, and the busiest processes of the latest sweep.
    private func processSection(_ database: Database, now: Int64) throws {
        var sampleId: Int64?, procDt = 1.0
        try database.query("""
            SELECT s.sample_id, s.proc_dt_ms, y.proc_count, y.thread_count, y.runnable_wait_ms, y.unattributed_cpu_ms
            FROM sample s JOIN sys_sample y USING (sample_id) WHERE s.proc_dt_ms IS NOT NULL ORDER BY s.sample_id DESC LIMIT 1
            """) { r in
            sampleId = r.int(0); procDt = max(Double(r.int(1)), 1)
            let own = (try? database.scalarInt("SELECT COUNT(*) FROM process WHERE exited_ts IS NULL AND source = 0")) ?? 0
            line("processes", "\(r.int(2)) running (\(own) readable without root), \(r.int(3)) threads in readable ones")
            line("contention", "\(fmt(Double(r.int(4)) / procDt, 2)) cores' worth of threads waiting"
                 + (r.isNull(5) ? "" : ", \(pct(Double(r.int(5)), procDt)) of a core not attributed to readable processes"))
        }
        guard let sampleId else { return }

        // The daemon's own cost over the last five minutes (its rows are always stored).
        try database.query("""
            SELECT SUM(p.cpu_user_ms + p.cpu_sys_ms) * 100.0 / SUM(s.proc_dt_ms), MAX(p.footprint), MAX(p.sample_id)
            FROM proc_sample p JOIN sample s USING (sample_id) WHERE p.reason & 8 AND s.ts >= ?
            """, [now - 300_000]) { r in
            guard !r.isNull(0) else { return }
            let level = (try? database.scalarInt("SELECT value FROM event WHERE kind = 'collector_backoff' ORDER BY event_id DESC LIMIT 1")) ?? nil
            line("monitor", "\(fmt(r.double(0), 2)) % of a core, \(bytes(r.int(1))) (5-minute average)"
                 + ((level ?? 0) > 0 ? ", self-limiter at level \(level!)" : ""))
        }

        for (title, order) in [("top cpu", "(p.cpu_user_ms + p.cpu_sys_ms) DESC"), ("top memory", "p.footprint DESC")] {
            var first = true
            try database.query("""
                SELECT e.name, pr.pid, (p.cpu_user_ms + p.cpu_sys_ms) * 100.0 / ?, p.footprint
                FROM proc_sample p JOIN process pr USING (proc_id) JOIN executable e USING (exe_id)
                WHERE p.sample_id = ? ORDER BY \(order) LIMIT 5
                """, [procDt, sampleId]) { r in
                let name = r.text(0).padding(toLength: 28, withPad: " ", startingAt: 0)
                let text = "\(name) pid \(String(r.int(1)).padding(toLength: 6, withPad: " ", startingAt: 0)) "
                    + "\(fmt(r.double(2), 1).leftPad(6)) % cpu  \(bytes(r.int(3)).leftPad(8))"
                line(first ? title : "", text)
                first = false
            }
        }
    }

    private func line(_ label: String, _ value: String) {
        print(label.padding(toLength: 12, withPad: " ", startingAt: 0) + value)
    }
    private func fmt(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", v) }
    private func pct(_ part: Double, _ whole: Double) -> String { whole > 0 ? fmt(part / whole * 100, 1) + " %" : "–" }
    private func bytes(_ v: Int64) -> String {
        let d = Double(v), kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if d >= gb { return fmt(d / gb, 1) + " GB" }
        if d >= mb { return fmt(d / mb, 0) + " MB" }
        if d >= kb { return fmt(d / kb, 0) + " kB" }
        return "\(v) B"
    }
}

extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
