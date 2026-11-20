import ArgumentParser
import Foundation
import PmonCore

/// Print a value as pretty JSON with stable key order.
func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
    print(String(decoding: data, as: UTF8.self))
}

/// One query function per report, shared by the text, JSON and HTML outputs.
enum Queries {
    /// The rollup grain that covers `spanMs` with a sensible number of rows.
    static func grain(for spanMs: Int64) -> (suffix: String, bucketMs: Int64) {
        if spanMs <= 3 * 3_600_000 { return ("1m", 60_000) }
        if spanMs <= 14 * 86_400_000 { return ("1h", 3_600_000) }
        return ("1d", 86_400_000)
    }

    /// As above, but falls back to a finer grain when the coarse one has nothing yet (a bucket is
    /// only written once it is complete, so a young database has minutes before it has hours).
    static func grain(_ db: Database, since: Int64, now: Int64) throws -> (suffix: String, bucketMs: Int64) {
        let all: [(suffix: String, bucketMs: Int64)] = [("1d", 86_400_000), ("1h", 3_600_000), ("1m", 60_000)]
        let preferred = grain(for: now - since)
        for g in all where g.bucketMs <= preferred.bucketMs {
            if (try db.scalarInt("SELECT COUNT(*) FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ?", [since - g.bucketMs]) ?? 0) > 0 { return g }
        }
        return preferred
    }

    struct Offender { var app: String, kind: String, minutes: Double, episodes: Int, via: String }

    /// Apps ranked by sluggish-minutes caused: blame share x episode length, summed.
    static func offenders(_ db: Database, since: Int64, includeAway: Bool, limit: Int = 10) throws -> [Offender] {
        var out: [Offender] = []
        try db.query("""
            SELECT a.name, a.kind, SUM(b.score * (e.end_ts - e.start_ts)) / 60000.0 AS minutes, COUNT(DISTINCT e.episode_id),
                   (SELECT b2.dim FROM episode_blame b2 JOIN episode e2 USING (episode_id)
                    WHERE b2.app_id = a.app_id AND b2.role = 'culprit' AND e2.start_ts >= ?1 GROUP BY b2.dim ORDER BY SUM(b2.score) DESC LIMIT 1)
            FROM episode e JOIN episode_blame b USING (episode_id) JOIN app a USING (app_id)
            WHERE e.start_ts >= ?1 AND e.end_ts IS NOT NULL AND b.role = 'culprit' AND (?2 = 1 OR e.user_present = 1)
            GROUP BY a.app_id HAVING minutes >= 0.005 ORDER BY minutes DESC LIMIT ?3
            """, [since, includeAway ? 1 : 0, limit]) { r in
            out.append(Offender(app: r.text(0), kind: r.text(1), minutes: r.double(2), episodes: Int(r.int(3)), via: r.optText(4) ?? ""))
        }
        return out
    }

    struct Totals { var episodes: Int, sluggishMs: Int64, away: Int, observedMs: Int64, presentMs: Int64 }

    /// `includeAway` counts slowdowns nobody was present for as well (they are otherwise only tallied in `away`).
    static func totals(_ db: Database, since: Int64, now: Int64, includeAway: Bool = false) throws -> Totals {
        var t = Totals(episodes: 0, sluggishMs: 0, away: 0, observedMs: 0, presentMs: 0)
        try db.query("SELECT COUNT(*), COALESCE(SUM(end_ts - start_ts), 0) FROM episode WHERE start_ts >= ? AND end_ts IS NOT NULL AND (user_present = 1 OR ? = 1)", [since, includeAway ? 1 : 0]) {
            t.episodes = Int($0.int(0)); t.sluggishMs = $0.int(1)
        }
        t.away = Int(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE start_ts >= ? AND end_ts IS NOT NULL AND user_present = 0", [since]) ?? 0)
        let g = try grain(db, since: since, now: now)
        try db.query("SELECT COALESCE(SUM(awake_ms), 0), COALESCE(SUM(user_present_ms), 0) FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ?", [since - g.bucketMs]) {
            t.observedMs = $0.int(0); t.presentMs = $0.int(1)
        }
        return t
    }

    struct Background { var app: String, kind: String, cpuCoreMinutes: Double, peakMb: Double, energyMwh: Double?, focusPct: Double, writtenMb: Double }

    /// What apps cost while (almost) never in front.
    static func background(_ db: Database, since: Int64, now: Int64, limit: Int = 8) throws -> [Background] {
        let g = try grain(db, since: since, now: now)
        var out: [Background] = []
        try db.query("""
            SELECT a.name, a.kind, SUM(r.cpu_ms) / 60000.0 AS cpu, MAX(r.footprint_max) / 1048576.0, SUM(r.energy_uj) / 3.6e6,
                   COALESCE(SUM(r.focus_ms), 0) * 100.0 / NULLIF(SUM(r.covered_ms), 0) AS focus, COALESCE(SUM(r.disk_write), 0) / 1048576.0
            FROM app_rollup_\(g.suffix) r JOIN app a USING (app_id)
            WHERE r.bucket_ts >= ? AND a.key NOT LIKE 'pmon.%' AND a.key NOT LIKE 'system.%'
            GROUP BY a.app_id HAVING focus < 5 AND cpu >= 0.05 ORDER BY cpu DESC LIMIT ?
            """, [since - g.bucketMs, limit]) { r in
            out.append(Background(app: r.text(0), kind: r.text(1), cpuCoreMinutes: r.double(2), peakMb: r.double(3), energyMwh: r.optDouble(4),
                                  focusPct: r.double(5), writtenMb: r.double(6)))
        }
        return out
    }

    struct Finding { var id: Int64, kind: String, app: String, severity: Int, first: Int64, last: Int64, status: String, evidence: [String: Any] }

    static func findings(_ db: Database, includeClosed: Bool, since: Int64 = 0) throws -> [Finding] {
        var out: [Finding] = []
        try db.query("""
            SELECT f.finding_id, f.kind, a.name, f.severity, COALESCE(f.first_ts, f.ts), COALESCE(f.last_ts, f.ts), f.status, f.evidence
            FROM finding f JOIN app a USING (app_id) WHERE (f.status = 'open' OR ?1 = 1) AND COALESCE(f.last_ts, f.ts) >= ?2
            ORDER BY (f.status = 'open') DESC, f.severity DESC, f.last_ts DESC
            """, [includeClosed ? 1 : 0, since]) { r in
            let ev = (try? JSONSerialization.jsonObject(with: Data(r.text(7).utf8))) as? [String: Any] ?? [:]
            out.append(Finding(id: r.int(0), kind: r.text(1), app: r.text(2), severity: Int(r.int(3)), first: r.int(4), last: r.int(5), status: r.text(6), evidence: ev))
        }
        return out
    }

    /// A finding in one sentence.
    static func sentence(_ f: Finding) -> String {
        func n(_ key: String, _ digits: Int = 0) -> String { Fmt.num((f.evidence[key] as? NSNumber)?.doubleValue ?? 0, digits) }
        switch f.kind {
        case "leak_suspect": return "\(f.app) may be leaking memory: up \(Fmt.size(mb: (f.evidence["growth_mb"] as? NSNumber)?.doubleValue ?? 0)) over \(n("hours")) hours (\(n("mb_per_hour")) MB per hour), now \(Fmt.size(mb: (f.evidence["now_mb"] as? NSNumber)?.doubleValue ?? 0))."
        case "runaway_cpu": return "\(f.app) used over 80 % of a core for \(n("minutes")) minutes in the background (peak \(n("peak_cpu_pct")) %)."
        case "wakeup_storm": return "\(f.app) woke the CPU about \(n("peak_wakeups_per_s")) times a second for \(n("minutes")) minutes; that costs battery."
        case "disk_writer": return "\(f.app) wrote \(n("written_gb", 1)) GB in 24 hours while in focus \(n("focus_pct")) % of the time."
        case "anomaly":
            let metric = f.evidence["metric"] as? String == "cpu_pct" ? "CPU" : "memory"
            let unit = metric == "CPU" ? " % of a core" : " MB"
            return "\(f.app) is far above its usual \(metric): \(n("value"))\(unit) in the last hour, normally under \(n("usual_p95"))."
        case "crash_loop": return "\(f.app) crashed \(n("crashes_in_hour")) times within an hour."
        case "disk_nearly_full": return "The system volume has \(n("free_gb", 1)) GB free (\(n("free_pct", 1)) %). A nearly full disk slows writes and leaves little room for swap."
        default: return "\(f.app): \(f.kind)"
        }
    }

    struct TimelinePoint { var ts: Int64, avg: Double?, max: Int?, sluggishMs: Int64, coveredMs: Int64 }

    static func timeline(_ db: Database, since: Int64, now: Int64) throws -> (points: [TimelinePoint], bucketMs: Int64) {
        let g = try grain(db, since: since, now: now)
        var out: [TimelinePoint] = []
        try db.query("SELECT bucket_ts, slug_index_avg, slug_index_max, sluggish_ms, covered_ms FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= ? ORDER BY bucket_ts", [since - g.bucketMs]) { r in
            out.append(TimelinePoint(ts: r.int(0), avg: r.optDouble(1), max: r.optInt(2).map { Int($0) }, sluggishMs: r.int(3), coveredMs: r.int(4)))
        }
        return (out, g.bucketMs)
    }

    static func episodes(_ db: Database, since: Int64, now: Int64) throws -> [Episode] {
        var list: [Episode] = []
        try db.query("SELECT \(Episode.columns) FROM episode e WHERE COALESCE(e.end_ts, ?) >= ? ORDER BY e.start_ts", [now, since]) { list.append(Episode($0)) }
        return list
    }
}

extension Episode {
    func json(now: Int64, blame: [Blame]) -> [String: Any] {
        ["id": id, "start_ms": start, "end_ms": end ?? NSNull(), "duration_s": Double((end ?? now) - start) / 1000, "peak": peak, "mean": mean,
         "bottleneck": dominant, "scores": means, "user_present": userPresent, "focus_app": focusApp ?? NSNull(),
         "on_battery": onBattery, "low_power": lowPower, "after_wake": afterWake,
         "blame": blame.map { ["app": $0.app, "kind": $0.kind, "dimension": $0.dim, "share": $0.share, "score": $0.score, "role": $0.role,
                               "confidence": ["low", "medium", "high"][min(max($0.confidence, 0), 2)], "top_process": $0.topProcess ?? NSNull(), "detail": $0.detail] as [String: Any] }]
    }
}

struct Top: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rank applications by how much slowdown they caused, and show what runs in the background.")

    @Option(help: "How far back to look, e.g. 24h or 7d.") var since = "7d"
    @Flag(help: "Include slowdowns during which nobody was at the Mac.") var all = false
    @Flag(help: "Output JSON.") var json = false
    @Option(help: "Database file.") var db: String = PmonPaths.database

    func run() throws {
        let database = try Database(path: db, readOnly: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000), from = now - (try Fmt.span(since))
        let offenders = try Queries.offenders(database, since: from, includeAway: all)
        let totals = try Queries.totals(database, since: from, now: now, includeAway: all)
        let background = try Queries.background(database, since: from, now: now)
        if json {
            printJSON(["since_ms": from, "slowdowns": totals.episodes, "sluggish_minutes": Double(totals.sluggishMs) / 60_000, "slowdowns_while_away": totals.away,
                       "observed_hours": Double(totals.observedMs) / 3_600_000,
                       "offenders": offenders.map { ["app": $0.app, "kind": $0.kind, "sluggish_minutes_caused": $0.minutes, "episodes": $0.episodes, "mostly_via": $0.via] as [String: Any] },
                       "background": background.map { ["app": $0.app, "kind": $0.kind, "cpu_core_minutes": $0.cpuCoreMinutes, "peak_mb": $0.peakMb,
                                                       "energy_mwh": $0.energyMwh ?? NSNull(), "focus_pct": $0.focusPct, "written_mb": $0.writtenMb] as [String: Any] }])
            return
        }
        print("Last \(since): \(Fmt.duration(totals.observedMs)) observed, \(totals.episodes) slowdown\(totals.episodes == 1 ? "" : "s") "
              + (all ? "" : "while you were at the Mac ") + "(\(Fmt.duration(totals.sluggishMs)) in total)"
              + (!all && totals.away > 0 ? ", \(totals.away) more while away (--all includes them)" : "") + ".")
        print("")
        if offenders.isEmpty {
            print("No application caused a measurable slowdown.")
        } else {
            print("slowdown caused         episodes  mostly through         application")
            for o in offenders {
                print("\((Fmt.num(o.minutes, 1) + " min").padding(toLength: 22, withPad: " ", startingAt: 0))  \(String(o.episodes).padding(toLength: 8, withPad: " ", startingAt: 0))  "
                      + "\((Fmt.dimensionNames[o.via] ?? o.via).padding(toLength: 21, withPad: " ", startingAt: 0))  \(o.app)\(o.kind == "app" ? "" : " (\(o.kind))")")
            }
        }
        if !background.isEmpty {
            print("\nBackground cost (in focus less than 5 % of the time)")
            print("cpu, core-minutes  peak memory  written    application")
            for b in background {
                print("\(Fmt.num(b.cpuCoreMinutes, 1).padding(toLength: 17, withPad: " ", startingAt: 0))  \(Fmt.size(mb: b.peakMb).padding(toLength: 11, withPad: " ", startingAt: 0))  "
                      + "\(Fmt.size(mb: b.writtenMb).padding(toLength: 9, withPad: " ", startingAt: 0))  \(b.app)\(b.kind == "app" ? "" : " (\(b.kind))")")
            }
        }
    }
}

struct FindingsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "findings", abstract: "Show chronic problems: leaks, runaway processes, wakeup storms, heavy writers, anomalies.")

    @Flag(help: "Include findings that are no longer active.") var all = false
    @Flag(help: "Output JSON.") var json = false
    @Option(help: "Database file.") var db: String = PmonPaths.database

    func run() throws {
        let database = try Database(path: db, readOnly: true)
        let list = try Queries.findings(database, includeClosed: all)
        if json {
            printJSON(list.map { ["id": $0.id, "kind": $0.kind, "app": $0.app, "severity": $0.severity, "first_ms": $0.first, "last_ms": $0.last,
                                  "status": $0.status, "evidence": $0.evidence, "text": Queries.sentence($0)] as [String: Any] })
            return
        }
        guard !list.isEmpty else { print("No findings\(all ? "" : " at the moment")."); return }
        for f in list {
            let tag = f.status == "open" ? (f.severity >= 2 ? "!!" : "! ") : "  "
            print("\(tag) \(Queries.sentence(f))")
            print("     \(f.status == "open" ? "active since" : "seen") \(Fmt.day(f.first)) \(Fmt.clock(f.first))\(f.status == "open" ? "" : " until \(Fmt.day(f.last)) \(Fmt.clock(f.last))")")
        }
    }
}

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export recorded data as JSON or CSV, for use in other tools.")

    enum Table: String, ExpressibleByArgument, CaseIterable { case episodes, blame, findings, apps, system, events }
    enum Format: String, ExpressibleByArgument, CaseIterable { case json, csv }

    @Argument(help: "What to export: \(Table.allCases.map(\.rawValue).joined(separator: ", ")). `apps` and `system` come from the rollups.")
    var table: Table
    @Option(help: "json or csv.") var format = Format.json
    @Option(help: "How far back to look, e.g. 24h or 7d.") var since = "7d"
    @Option(help: "Database file.") var db: String = PmonPaths.database

    func run() throws {
        let database = try Database(path: db, readOnly: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000), from = now - (try Fmt.span(since))
        let g = try Queries.grain(database, since: from, now: now)
        let sql: String
        switch table {
        case .episodes:
            sql = """
                SELECT e.episode_id, e.start_ts, e.end_ts, e.peak_index, e.mean_index, e.dominant, e.m_cpu, e.m_mem, e.m_disk, e.m_thermal, e.m_ui,
                       e.user_present, (SELECT name FROM app a WHERE a.app_id = e.focus_app_id) AS focus_app, e.on_battery, e.low_power, e.after_wake
                FROM episode e WHERE e.start_ts >= \(from) ORDER BY e.start_ts
                """
        case .blame:
            sql = """
                SELECT b.episode_id, e.start_ts, a.name AS app, a.kind, b.dim, b.share, b.score, b.role, b.confidence, b.detail
                FROM episode_blame b JOIN episode e USING (episode_id) JOIN app a USING (app_id) WHERE e.start_ts >= \(from) ORDER BY e.start_ts, b.score DESC
                """
        case .findings:
            sql = "SELECT f.finding_id, f.kind, a.name AS app, f.severity, f.first_ts, f.last_ts, f.status, f.evidence FROM finding f JOIN app a USING (app_id) WHERE COALESCE(f.last_ts, f.ts) >= \(from) ORDER BY f.ts"
        case .apps:
            sql = """
                SELECT r.bucket_ts, a.name AS app, a.kind, r.covered_ms, r.cpu_ms, r.cpu_fg_ms, r.cpu_util_ms, r.cpu_bg_ms, r.cpu_pct_max, r.footprint_avg, r.footprint_max,
                       r.disk_read, r.disk_write, r.wakeups, r.energy_uj, r.pageins, r.focus_ms, r.sluggish_ms, r.blame, r.proc_max, r.launches
                FROM app_rollup_\(g.suffix) r JOIN app a USING (app_id) WHERE r.bucket_ts >= \(from - g.bucketMs) ORDER BY r.bucket_ts, r.cpu_ms DESC
                """
        case .system:
            sql = "SELECT * FROM sys_rollup_\(g.suffix) WHERE bucket_ts >= \(from - g.bucketMs) ORDER BY bucket_ts"
        case .events:
            sql = "SELECT v.ts, v.kind, (SELECT name FROM app a WHERE a.app_id = v.app_id) AS app, v.value, v.detail FROM event v WHERE v.ts >= \(from) ORDER BY v.ts"
        }
        var header: [String] = [], rows: [[Any]] = []
        try database.query(sql) { r in
            if header.isEmpty { header = (0..<r.columnCount).map { r.name($0) } }
            rows.append((0..<r.columnCount).map { i -> Any in
                if r.isNull(i) { return NSNull() }
                let text = r.text(i)
                if let n = Int64(text) { return n }
                if let d = Double(text) { return d }
                return text
            })
        }
        switch format {
        case .json:
            printJSON(rows.map { row in Dictionary(uniqueKeysWithValues: zip(header, row)) })
        case .csv:
            func cell(_ v: Any) -> String {
                if v is NSNull { return "" }
                let s = "\(v)"
                return s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
            }
            print(header.joined(separator: ","))
            for row in rows { print(row.map(cell).joined(separator: ",")) }
        }
    }
}
