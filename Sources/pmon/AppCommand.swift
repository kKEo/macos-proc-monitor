import ArgumentParser
import Foundation
import PmonCore

struct AppCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "app", abstract: "Show one application: its processes and its last hour.")

    @Argument(help: "Application name or part of it (or its bundle identifier).")
    var name: String

    @Option(help: "Database file.")
    var db: String = PmonPaths.database

    func run() throws {
        let database = try Database(path: db, readOnly: true)
        var matches: [(id: Int64, name: String, kind: String, key: String, bundle: String?)] = []
        try database.query("""
            SELECT app_id, name, kind, key, bundle_path FROM app
            WHERE name LIKE ? OR key LIKE ? ORDER BY (name = ?) DESC, (kind = 'app') DESC, last_seen DESC
            """, ["%\(name)%", "%\(name)%", name]) { r in
            matches.append((r.int(0), r.text(1), r.text(2), r.text(3), r.optText(4)))
        }
        guard let app = matches.first else {
            print("No application matching \"\(name)\".")
            throw ExitCode(1)
        }
        if matches.count > 1, matches[0].name.caseInsensitiveCompare(name) != .orderedSame {
            print("Several applications match; showing the first. Others: " + matches.dropFirst().prefix(8).map(\.name).joined(separator: ", "))
        }

        print("\(app.name)  (\(app.kind))")
        print("  key        \(app.key)")
        if let b = app.bundle { print("  bundle     \(b)") }

        // Last hour, from the complete app-level rows.
        let now = Int64(Date().timeIntervalSince1970 * 1000), since = now - 3_600_000
        // Only ticks that have app-level rows count as observed (older data predates app grouping).
        let observedMs = try database.scalarInt("""
            SELECT SUM(proc_dt_ms) FROM sample WHERE proc_dt_ms IS NOT NULL AND ts >= ?
              AND sample_id IN (SELECT DISTINCT sample_id FROM app_sample)
            """, [since]) ?? 0
        try database.query("""
            SELECT SUM(x.cpu_ms), MAX(x.cpu_ms * 100.0 / s.proc_dt_ms), MAX(x.footprint),
                   (SELECT footprint FROM app_sample WHERE app_id = ?1 AND footprint IS NOT NULL ORDER BY sample_id DESC LIMIT 1),
                   SUM(x.d_disk_read), SUM(x.d_disk_write), SUM(x.d_wakeups), SUM(x.d_energy_uj), SUM(x.runnable_ms), COUNT(*), MAX(x.fidelity)
            FROM app_sample x JOIN sample s USING (sample_id) WHERE x.app_id = ?1 AND s.ts >= ?2
            """, [app.id, since]) { r in
            guard r.int(9) > 0, observedMs > 0 else { print("  no activity recorded in the last hour"); return }
            let hours = Double(observedMs) / 3_600_000
            print("  last hour  (\(fmt(Double(observedMs) / 60_000, 0)) min observed)")
            print("    cpu        \(fmt(Double(r.int(0)) * 100 / Double(observedMs), 2)) % of a core on average, peak \(fmt(r.double(1), 0)) %")
            print("    memory     \(bytes(r.int(3))) now, peak \(bytes(r.int(2)))")
            if !r.isNull(4) || !r.isNull(5) { print("    disk       \(bytes(r.int(4))) read, \(bytes(r.int(5))) written") }
            if !r.isNull(6) { print("    wakeups    \(fmt(Double(r.int(6)) / (hours * 3600), 0)) per second") }
            if !r.isNull(7) { print("    energy     \(fmt(Double(r.int(7)) / 3.6e6, 1)) mWh") }
            if !r.isNull(8) { print("    waiting    \(fmt(Double(r.int(8)) / 1000, 1)) s of thread time spent waiting for a core") }
            if r.int(10) > 0 { print("    note       some figures come from the top stream or ps (system-owned processes): no disk or energy for those") }
        }
        let focusMs = try database.scalarInt("""
            SELECT SUM(MIN(COALESCE(end_ts, ?1), ?1) - MAX(start_ts, ?2)) FROM focus_span
            WHERE app_id = ?3 AND COALESCE(end_ts, ?1) > ?2
            """, [now, since, app.id]) ?? 0
        if focusMs > 0 { print("    in focus   \(fmt(Double(focusMs) / 60_000, 1)) min") }

        print("  processes running now")
        var any = false
        try database.query("""
            SELECT p.pid, e.name, p.attribution, p.source, p.start_ts,
                   (SELECT footprint FROM proc_sample WHERE proc_id = p.proc_id AND footprint IS NOT NULL ORDER BY sample_id DESC LIMIT 1)
            FROM process p JOIN executable e USING (exe_id) WHERE p.app_id = ? AND p.exited_ts IS NULL ORDER BY 6 DESC, p.pid LIMIT 25
            """, [app.id]) { r in
            any = true
            let age = Double(now - r.int(4)) / 3_600_000
            let mem = r.isNull(5) ? "" : "  \(bytes(r.int(5)))"
            print("    \(String(r.int(0)).padding(toLength: 7, withPad: " ", startingAt: 0))\(r.text(1).padding(toLength: 30, withPad: " ", startingAt: 0))"
                  + " via \(r.text(2).padding(toLength: 11, withPad: " ", startingAt: 0)) up \(fmt(age, 1)) h\(r.int(3) == 1 ? "  (system-owned)" : "")\(mem)")
        }
        if !any { print("    none") }

        print("  busiest processes in the last hour")
        try database.query("""
            SELECT e.name, p.pid, SUM(x.cpu_user_ms + x.cpu_sys_ms), MAX(x.footprint)
            FROM proc_sample x JOIN sample s USING (sample_id) JOIN process p USING (proc_id) JOIN executable e USING (exe_id)
            WHERE p.app_id = ? AND s.ts >= ? GROUP BY p.proc_id ORDER BY 3 DESC LIMIT 5
            """, [app.id, since]) { r in
            print("    \(r.text(0).padding(toLength: 30, withPad: " ", startingAt: 0)) pid \(String(r.int(1)).padding(toLength: 7, withPad: " ", startingAt: 0))"
                  + " \(fmt(Double(r.int(2)) / 1000, 1)) s cpu\(r.isNull(3) ? "" : ", peak \(bytes(r.int(3)))")")
        }
    }

    private func fmt(_ v: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", v) }
    private func bytes(_ v: Int64) -> String {
        let d = Double(v), kb = 1024.0, mb = kb * 1024, gb = mb * 1024
        if d >= gb { return fmt(d / gb, 1) + " GB" }
        if d >= mb { return fmt(d / mb, 0) + " MB" }
        if d >= kb { return fmt(d / kb, 0) + " kB" }
        return "\(v) B"
    }
}
