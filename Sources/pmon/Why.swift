import ArgumentParser
import Foundation
import PmonCore

/// Parsing of command-line durations and times.
extension Fmt {
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
        print(Explain.text(e, try loadBlame(database, episode: e.id), now: now))
        let evidence = try Explain.evidence(database, e, now: now)
        if !evidence.isEmpty { print(evidence.joined(separator: "\n")) }
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
            print(Explain.text(e, blame, now: end))
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
