import Foundation

/// One recorded slowdown, as the explanation commands and the dashboard read it.
public struct Episode: Sendable, Identifiable, Hashable {
    public var id: Int64, start: Int64, end: Int64?
    public var peak: Int, mean: Int, dominant: String
    public var userPresent: Bool, focusApp: String?, onBattery: Bool, lowPower: Bool, afterWake: Bool
    public var means: [String: Int]

    public static let columns = """
        e.episode_id, e.start_ts, e.end_ts, e.peak_index, e.mean_index, e.dominant, e.user_present,
        (SELECT name FROM app a WHERE a.app_id = e.focus_app_id), e.on_battery, e.low_power, e.after_wake,
        e.m_cpu, e.m_mem, e.m_disk, e.m_thermal, e.m_gpu, e.m_ui
        """

    public init(_ r: Statement) {
        id = r.int(0); start = r.int(1); end = r.optInt(2)
        peak = Int(r.int(3)); mean = Int(r.int(4)); dominant = r.optText(5) ?? "cpu"
        userPresent = r.int(6) == 1; focusApp = r.optText(7)
        onBattery = r.int(8) == 1; lowPower = r.int(9) == 1; afterWake = r.int(10) == 1
        means = ["cpu": Int(r.int(11)), "memory": Int(r.int(12)), "disk": Int(r.int(13)), "thermal": Int(r.int(14)), "gpu": Int(r.int(15)), "ui": Int(r.int(16))]
    }
}

/// One application's share of one dimension of an episode.
public struct Blame: Sendable, Hashable {
    public var app: String, kind: String, dim: String, share: Double, score: Double, role: String, confidence: Int
    public var topProcess: String?, detail: [String: Double]
}

public func loadBlame(_ db: Database, episode: Int64) throws -> [Blame] {
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

/// Slowdowns in words.
public enum Explain {
    /// What an app did, in words, for one dimension.
    public static func describe(_ b: Blame) -> String {
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

    /// A piece of evidence found by the optional collectors.
    public struct Evidence: Sendable, Hashable {
        public var label: String, text: String
        /// The capture file, when there is one and it still exists.
        public var path: String?
    }

    /// What the optional collectors found: short-lived processes and capture files.
    public static func evidenceItems(_ db: Database, _ e: Episode, now: Int64) throws -> [Evidence] {
        var out: [Evidence] = []
        let end = e.end ?? now
        try db.query("""
            SELECT v.value, v.detail, a.name FROM event v LEFT JOIN app a USING (app_id)
            WHERE v.kind = 'short_lived' AND v.value >= 10 AND v.ts > ? AND v.ts <= ? ORDER BY v.value DESC LIMIT 3
            """, [e.start - 30_000, end + 120_000]) { r in
            let d = (r.optText(1).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            let top = ((d["top"] as? [[String: Any]]) ?? []).prefix(3).map { "\($0["count"] ?? 0) x \($0["name"] ?? "?")" }
            let process = (d["started_by"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let starter = [process, r.optText(2).map { process == nil || process == $0 ? $0 : "(\($0))" }].compactMap { $0 }.joined(separator: " ")
            out.append(Evidence(label: "Short-lived processes",
                                text: "\(top.joined(separator: ", ")), started by \(starter.isEmpty ? "an unknown process" : starter).", path: nil))
        }
        let labels = ["stack": "Call stacks", "procs": "Threads", "footprint": "Memory", "network": "Network"]
        try db.query("SELECT kind, summary, path FROM capture WHERE episode_id = ? ORDER BY capture_id", [e.id]) { r in
            let path = r.text(2)
            out.append(Evidence(label: labels[r.text(0)] ?? r.text(0), text: r.optText(1) ?? "",
                                path: FileManager.default.fileExists(atPath: path) ? path : nil))
        }
        return out
    }

    /// The evidence as text lines, as `pmon why` prints it.
    public static func evidence(_ db: Database, _ e: Episode, now: Int64) throws -> [String] {
        let items = try evidenceItems(db, e, now: now)
        let lines = items.map { $0.label == "Short-lived processes" ? "\($0.label): \($0.text)" : "\($0.label): \($0.text)\n    \($0.path ?? "file expired")" }
        return lines.isEmpty ? [] : ["", "Evidence:"] + lines.map { "  " + $0 }
    }

    /// The whole explanation as text.
    public static func text(_ e: Episode, _ blame: [Blame], now: Int64) -> String {
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
