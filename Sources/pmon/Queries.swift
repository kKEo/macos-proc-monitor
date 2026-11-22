import ArgumentParser
import Foundation
import PmonCore

/// Print a value as pretty JSON with stable key order.
func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("null".utf8)
    print(String(decoding: data, as: UTF8.self))
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
