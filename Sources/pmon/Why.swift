import ArgumentParser
import Foundation
import PmonCore

/// Shared formatting for the explanation commands.
enum Fmt {
    static func num(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }
    static func size(mb: Double) -> String { mb >= 1024 ? num(mb / 1024, 1) + " GB" : num(mb) + " MB" }
    static func duration(_ ms: Int64) -> String {
        let s = Double(ms) / 1000
        if s < 90 { return num(s) + " s" }
        if s < 5400 { return num(s / 60, s < 600 ? 1 : 0) + " min" }
        return num(s / 3600, 1) + " h"
    }
    static func clock(_ ms: Int64, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    static func day(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    static let dimensionNames = ["cpu": "CPU contention", "memory": "memory pressure", "disk": "disk I/O saturation",
                                 "thermal": "thermal throttling", "gpu": "GPU saturation", "ui": "an unresponsive app"]

    /// "2h", "90m", "3d", "45s" -> milliseconds.
    static func span(_ text: String) throws -> Int64 {
        guard let unit = text.last, let n = Double(text.dropLast()) else { throw ValidationError("expected a duration such as 30m, 6h or 7d") }
        switch unit {
        case "s": return Int64(n * 1000)
        case "m": return Int64(n * 60_000)
        case "h": return Int64(n * 3_600_000)
        case "d": return Int64(n * 86_400_000)
        default: throw ValidationError("expected a duration such as 30m, 6h or 7d")
        }
    }

    /// "14:32" or "14:32:10" today, or "2026-11-20 14:32" -> Unix milliseconds.
    static func time(_ text: String) throws -> Int64 {
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "HH:mm:ss", "HH:mm"] {
            let f = DateFormatter()
            f.dateFormat = format
            guard let d = f.date(from: text) else { continue }
            if format.hasPrefix("yyyy") { return Int64(d.timeIntervalSince1970 * 1000) }
            let cal = Calendar.current
            var parts = cal.dateComponents([.year, .month, .day], from: Date())
            let hms = cal.dateComponents([.hour, .minute, .second], from: d)
            parts.hour = hms.hour; parts.minute = hms.minute; parts.second = hms.second
            if let today = cal.date(from: parts) { return Int64(today.timeIntervalSince1970 * 1000) }
        }
        throw ValidationError("expected a time such as 14:32 or \"2026-11-20 14:32\"")
    }
}

struct Episode {
    var id: Int64, start: Int64, end: Int64?
    var peak: Int, mean: Int, dominant: String
    var userPresent: Bool, focusApp: String?, onBattery: Bool, lowPower: Bool, afterWake: Bool
    var means: [String: Int]

    static let columns = """
        e.episode_id, e.start_ts, e.end_ts, e.peak_index, e.mean_index, e.dominant, e.user_present,
        (SELECT name FROM app a WHERE a.app_id = e.focus_app_id), e.on_battery, e.low_power, e.after_wake,
        e.m_cpu, e.m_mem, e.m_disk, e.m_thermal, e.m_gpu, e.m_ui
        """

    init(_ r: Statement) {
        id = r.int(0); start = r.int(1); end = r.optInt(2)
        peak = Int(r.int(3)); mean = Int(r.int(4)); dominant = r.optText(5) ?? "cpu"
        userPresent = r.int(6) == 1; focusApp = r.optText(7)
        onBattery = r.int(8) == 1; lowPower = r.int(9) == 1; afterWake = r.int(10) == 1
        means = ["cpu": Int(r.int(11)), "memory": Int(r.int(12)), "disk": Int(r.int(13)), "thermal": Int(r.int(14)), "gpu": Int(r.int(15)), "ui": Int(r.int(16))]
    }
}

struct Blame {
    var app: String, kind: String, dim: String, share: Double, score: Double, role: String, confidence: Int
    var topProcess: String?, detail: [String: Double]
}

func loadBlame(_ db: Database, episode: Int64) throws -> [Blame] {
    var rows: [Blame] = []
    try db.query("""
        SELECT a.name, a.kind, b.dim, b.share, b.score, b.role, b.confidence,
               (SELECT e.name FROM process p JOIN executable e USING (exe_id) WHERE p.proc_id = b.top_proc_id), b.detail
        FROM episode_blame b JOIN app a USING (app_id) WHERE b.episode_id = ? ORDER BY b.score DESC, b.share DESC
        """, [episode]) { r in
        let detail = (r.optText(8).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Double]) ?? [:]
        rows.append(Blame(app: r.text(0), kind: r.text(1), dim: r.text(2), share: r.double(3), score: r.double(4), role: r.text(5),
                          confidence: Int(r.int(6)), topProcess: r.optText(7), detail: detail))
    }
    return rows
}

/// What an app did, in words, for one dimension.
func describe(_ b: Blame) -> String {
    let d = b.detail
    switch b.dim {
    case "cpu":
        if b.role == "victim" { return "spent \(Fmt.num(d["wait_s"] ?? 0)) s waiting for a core" }
        if let n = d["short_lived_count"] {
            let churn = "started short-lived processes that used the CPU (\(Fmt.num(n)) seen in a scan)"
            return d["cpu_pct"] == nil ? churn : "used \(Fmt.num(d["cpu_pct"] ?? 0)) % of a core itself and \(churn)"
        }
        return "used \(Fmt.num(d["cpu_pct"] ?? 0)) % of a core (peak \(Fmt.num(d["peak_cpu_pct"] ?? 0)) %)"
    case "memory":
        if b.role == "victim" { return "had \(Fmt.num(d["pageins"] ?? 0)) page-ins while holding little memory itself" }
        var parts = ["held \(Fmt.size(mb: d["held_mb"] ?? 0))"]
        if let g = d["growth_mb"], g >= 20 { parts.append("grew by \(Fmt.size(mb: g)) in the 10 minutes before") }
        return parts.joined(separator: " and ")
    case "disk": return "read and wrote \(Fmt.size(mb: d["disk_mb"] ?? 0)) (\(Fmt.num(d["mb_per_s"] ?? 0)) MB/s)"
    case "thermal": return "used \(Fmt.num(d["energy_mwh"] ?? 0, 1)) mWh in the minutes before and during"
    case "gpu": return "used \(Fmt.num(d["gpu_pct"] ?? 0)) % of the GPU's time"
    case "ui": return "was reported unresponsive by the system"
    default: return ""
    }
}

struct Why: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Explain a slowdown: what was the bottleneck and which applications caused it.")

    @Option(help: "Time of interest, e.g. 14:32 or \"2026-11-20 14:32\". Default: now.")
    var at: String?

    @Flag(help: "Output JSON.") var json = false

    @Option(help: "Database file.")
    var db: String = PmonPaths.database

    func run() throws {
        let database = try Database(path: db, readOnly: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let target = try at.map(Fmt.time) ?? now

        // The episode containing the moment, else the nearest one within an hour of it.
        var episode: Episode?
        try database.query("""
            SELECT \(Episode.columns) FROM episode e
            WHERE e.start_ts <= ?1 + 3600000 AND COALESCE(e.end_ts, ?2) >= ?1 - 3600000
            ORDER BY CASE WHEN ?1 BETWEEN e.start_ts AND COALESCE(e.end_ts, ?2) THEN 0 ELSE MIN(ABS(e.start_ts - ?1), ABS(COALESCE(e.end_ts, ?2) - ?1)) END
            LIMIT 1
            """, [target, now]) { episode = Episode($0) }

        if json {
            printJSON(try episode.map { $0.json(now: now, blame: try loadBlame(database, episode: $0.id)) } ?? ["episode": NSNull()])
            return
        }
        guard let e = episode else {
            print("No slowdown recorded within an hour of \(Fmt.clock(target)).")
            try database.query("SELECT y.slug_index, y.s_cpu, y.s_mem, y.s_disk, y.s_thermal, y.s_ui FROM sys_sample y JOIN sample s USING (sample_id) WHERE s.ts <= ? AND y.slug_index IS NOT NULL ORDER BY s.sample_id DESC LIMIT 1", [target]) { r in
                print("Sluggishness index then: \(r.int(0)) of 100 (cpu \(r.int(1)), memory \(r.int(2)), disk \(r.int(3)), thermal \(r.int(4)), ui \(r.int(5))). An episode opens at 60.")
            }
            return
        }
        print(Why.explain(e, try loadBlame(database, episode: e.id), now: now))
        let evidence = try Why.evidence(database, e, now: now)
        if !evidence.isEmpty { print(evidence.joined(separator: "\n")) }
    }

    /// What the optional collectors found: short-lived processes and capture files.
    static func evidence(_ db: Database, _ e: Episode, now: Int64) throws -> [String] {
        var out: [String] = []
        let end = e.end ?? now
        try db.query("""
            SELECT v.value, v.detail, a.name FROM event v LEFT JOIN app a USING (app_id)
            WHERE v.kind = 'short_lived' AND v.value >= 10 AND v.ts > ? AND v.ts <= ? ORDER BY v.value DESC LIMIT 3
            """, [e.start - 30_000, end + 120_000]) { r in
            let d = (r.optText(1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            let top = ((d["top"] as? [[String: Any]]) ?? []).prefix(3).map { "\($0["count"] ?? 0) x \($0["name"] ?? "?")" }
            let process = (d["started_by"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let starter = [process, r.optText(2).map { process == nil || process == $0 ? $0 : "(\($0))" }].compactMap { $0 }.joined(separator: " ")

            out.append("Short-lived processes: \(top.joined(separator: ", ")), started by \(starter.isEmpty ? "an unknown process" : starter).")
        }
        let labels = ["stack": "Call stacks", "procs": "Threads", "footprint": "Memory", "network": "Network"]
        try db.query("SELECT kind, summary, path FROM capture WHERE episode_id = ? ORDER BY capture_id", [e.id]) { r in
            let path = r.text(2)
            let file = FileManager.default.fileExists(atPath: path) ? path : "file expired"
            out.append("\(labels[r.text(0)] ?? r.text(0)): \(r.optText(1) ?? "")\n    \(file)")
        }
        return out.isEmpty ? [] : ["", "Evidence:"] + out.map { "  " + $0 }
    }

    /// The whole explanation as text.
    static func explain(_ e: Episode, _ blame: [Blame], now: Int64) -> String {
        var out: [String] = []
        let end = e.end ?? now
        let when = "\(Fmt.day(e.start)) \(Fmt.clock(e.start, seconds: end - e.start < 120_000))–\(Fmt.clock(end, seconds: end - e.start < 120_000))"
        let state = e.end == nil ? "still going" : Fmt.duration(end - e.start)
        out.append("\(when) (\(state)): \(Fmt.dimensionNames[e.dominant] ?? e.dominant), peak \(e.peak) of 100.")

        let others = e.means.filter { $0.key != e.dominant && $0.value >= 30 }.sorted { $0.value > $1.value }
        if !others.isEmpty { out.append("Also elevated: " + others.map { "\(Fmt.dimensionNames[$0.key] ?? $0.key) (\($0.value))" }.joined(separator: ", ") + ".") }

        if e.end == nil {
            out.append("Causes are worked out when the episode ends; `pmon status` shows what is busy right now.")
        } else if blame.isEmpty {
            out.append("No application stands out: the episode was too short to attribute, or its data has expired.")
        } else {
            let culprits = blame.filter { $0.role == "culprit" && $0.dim == e.dominant }
            for (i, b) in culprits.prefix(3).enumerated() {
                let via = b.topProcess.map { $0 == b.app ? "" : ", mostly \($0)" } ?? ""
                let sure = b.confidence == 0 ? " (estimate: these processes cannot be told apart without the root helper)" : (b.confidence == 1 ? " (system-owned, coarser data)" : "")
                out.append("\(i == 0 ? "Main cause" : "Also"): \(b.app) — \(Fmt.num(b.share * 100)) % of it; \(describe(b))\(via)\(sure).")
            }
            if culprits.isEmpty { out.append("No single application accounts for a meaningful share.") }
            for b in blame.filter({ $0.role == "culprit" && $0.dim != e.dominant }).prefix(2) where b.score >= 0.1 {
                out.append("Contributing through \(Fmt.dimensionNames[b.dim] ?? b.dim): \(b.app) — \(describe(b)).")
            }
            for b in blame.filter({ $0.role == "victim" }).prefix(2) {
                out.append("Affected rather than responsible: \(b.app)\(b.app == e.focusApp ? " (in focus)" : "") — \(describe(b)).")
            }
        }

        var context: [String] = []
        if let f = e.focusApp { context.append("\(f) was in focus") }
        context.append(e.userPresent ? "you were at the Mac" : "nobody was at the Mac")
        if e.lowPower { context.append("Low Power Mode was on") } else if e.onBattery { context.append("on battery") }
        if e.afterWake { context.append("it began right after waking from sleep") }
        out.append("Context: " + context.joined(separator: "; ") + ".")
        return out.joined(separator: "\n")
    }
}

struct Episodes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List recorded slowdowns.")

    @Option(help: "How far back to look, e.g. 6h or 7d.")
    var since = "24h"

    @Flag(help: "Include episodes during which nobody was at the Mac.")
    var all = false

    @Flag(help: "Output JSON.") var json = false

    @Option(help: "Database file.")
    var db: String = PmonPaths.database

    func run() throws {
        let database = try Database(path: db, readOnly: true)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        var list: [Episode] = []
        try database.query("SELECT \(Episode.columns) FROM episode e WHERE COALESCE(e.end_ts, ?) >= ? ORDER BY e.start_ts", [now, now - (try Fmt.span(since))]) {
            list.append(Episode($0))
        }
        let shown = all ? list : list.filter { $0.userPresent || $0.end == nil }
        if json {
            printJSON(try shown.map { $0.json(now: now, blame: try loadBlame(database, episode: $0.id)) })
            return
        }
        guard !shown.isEmpty else {
            print("No slowdowns in the last \(since)\(list.isEmpty ? "" : " while you were at the Mac (\(list.count) while away; --all shows them)").")
            return
        }
        print("when               length    peak  bottleneck            main cause")
        for e in shown {
            let end = e.end ?? now
            let cause = try loadBlame(database, episode: e.id).first { $0.role == "culprit" && $0.dim == e.dominant }
            let causeText = e.end == nil ? "(in progress)" : (cause.map { "\($0.app) (\(Fmt.num($0.share * 100)) %)" } ?? "–")
            print("\(Fmt.day(e.start).padding(toLength: 11, withPad: " ", startingAt: 0)) \(Fmt.clock(e.start))  "
                  + "\(Fmt.duration(end - e.start).padding(toLength: 8, withPad: " ", startingAt: 0))  \(String(e.peak).padding(toLength: 4, withPad: " ", startingAt: 0))  "
                  + "\((Fmt.dimensionNames[e.dominant] ?? e.dominant).padding(toLength: 20, withPad: " ", startingAt: 0))  \(causeText)\(e.userPresent ? "" : "  [away]")")
        }
        let total = shown.reduce(Int64(0)) { $0 + (($1.end ?? now) - $1.start) }
        print("\(shown.count) slowdown\(shown.count == 1 ? "" : "s"), \(Fmt.duration(total)) in total. `pmon why --at HH:MM` explains one.")
    }
}

struct Mark: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record \"it feels slow right now\". Used to calibrate detection against how the Mac actually feels.")

    @Argument(help: "Optional note.")
    var note: [String] = []

    @Option(help: "Database file.")
    var db: String = PmonPaths.database

    func run() throws {
        guard FileManager.default.fileExists(atPath: db) else { throw ValidationError("no database at \(db); is the daemon installed?") }
        // A second, brief writer next to the daemon: SQLite's write-ahead log allows this.
        let database = try Database(path: db)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let text = note.joined(separator: " ")
        let detail = text.isEmpty ? nil : String(decoding: try JSONSerialization.data(withJSONObject: ["note": text]), as: UTF8.self)
        try database.run("INSERT INTO event (ts, kind, detail) VALUES (?, 'mark', ?)", [now, detail])
        var line = "Marked \(Fmt.clock(now, seconds: true))."
        try database.query("SELECT slug_index, s_cpu, s_mem, s_disk, s_thermal FROM sys_sample WHERE slug_index IS NOT NULL ORDER BY sample_id DESC LIMIT 1") { r in
            line += " Index right now: \(r.int(0)) (cpu \(r.int(1)), memory \(r.int(2)), disk \(r.int(3)), thermal \(r.int(4)))."
        }
        print(line)
    }
}

struct Calibrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Replay a recording with candidate thresholds and show the episodes they produce, next to any marks.")

    @Argument(help: "Recording file (.jsonl or .jsonl.gz) written by `pmond --record`.")
    var recording: String

    @Option(help: "JSON file with threshold overrides (any subset of fields).")
    var thresholds: String?

    @Flag(help: "Print the index and sub-scores of every sample.")
    var samples = false

    func run() throws {
        let t = try thresholds.map { try JSONDecoder().decode(Thresholds.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) } ?? Thresholds()
        let path = NSTemporaryDirectory() + "pmon-calibrate-\(getpid()).db"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let database = try Database(path: path)
        let ticks = try Replayer.replay(recording: recording, into: database, thresholds: t)
        let end = try database.scalarInt("SELECT MAX(ts) FROM sample") ?? 0

        if samples {
            print("time      index  cpu  mem  disk  therm  ui   wait%  thrash/s  queue")
            try database.query("""
                SELECT s.ts, y.slug_index, y.s_cpu, y.s_mem, y.s_disk, y.s_thermal, y.s_ui,
                       (SELECT yy.runnable_wait_ms * 100.0 / (ss.proc_dt_ms * 8) FROM sys_sample yy JOIN sample ss USING (sample_id)
                        WHERE ss.sample_id <= s.sample_id AND ss.proc_dt_ms IS NOT NULL ORDER BY ss.sample_id DESC LIMIT 1),
                       (y.d_decompressions + y.d_pageins + 4 * (y.d_swapins + y.d_swapouts)) * 1000.0 / s.dt_ms, y.disk_io_time_ms * 1.0 / s.dt_ms,
                       s.flags & 16
                FROM sample s JOIN sys_sample y USING (sample_id) ORDER BY s.sample_id
                """) { r in
                func col(_ i: Int, _ w: Int) -> String { String(r.int(i)).padding(toLength: w, withPad: " ", startingAt: 0) }
                print("\(Fmt.clock(r.int(0), seconds: true))  \(col(1, 5))  \(col(2, 3))  \(col(3, 3))  \(col(4, 4))  \(col(5, 5))  \(col(6, 3))  "
                      + "\(Fmt.num(r.double(7), 1).padding(toLength: 5, withPad: " ", startingAt: 0))  \(Fmt.num(r.double(8)).padding(toLength: 8, withPad: " ", startingAt: 0))  "
                      + "\(Fmt.num(r.double(9), 2))\(r.int(10) != 0 ? "   <episode>" : "")")
            }
        }

        var episodes: [Episode] = []
        try database.query("SELECT \(Episode.columns) FROM episode e ORDER BY e.start_ts") { episodes.append(Episode($0)) }
        var marks: [Int64] = []
        try database.query("SELECT ts FROM event WHERE kind = 'mark' ORDER BY ts") { marks.append($0.int(0)) }

        print("\(ticks) ticks replayed, \(episodes.count) episode\(episodes.count == 1 ? "" : "s"), \(marks.count) mark\(marks.count == 1 ? "" : "s").")
        for e in episodes {
            let blame = try loadBlame(database, episode: e.id)
            print("")
            print(Why.explain(e, blame, now: end))
            for b in blame.prefix(6) {
                print("    \(b.dim.padding(toLength: 8, withPad: " ", startingAt: 0)) \(b.role.padding(toLength: 8, withPad: " ", startingAt: 0)) "
                      + "\(Fmt.num(b.share * 100).padding(toLength: 4, withPad: " ", startingAt: 0))%  score \(Fmt.num(b.score, 2))  \(b.app)")
            }
        }
        if !marks.isEmpty {
            let inside = marks.filter { m in episodes.contains { m >= $0.start - 30_000 && m <= ($0.end ?? end) + 30_000 } }.count
            print("\n\(inside) of \(marks.count) marks fall inside an episode (within 30 s).")
        }
    }
}
