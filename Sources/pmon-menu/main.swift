import AppKit
import PmonCore

// pmon-menu — a menu-bar item showing the live sluggishness index and what is busy right now,
// and one dashboard window (live charts, history, slowdowns, findings, apps) that every menu entry opens.
// Read-only: it opens the database the daemon writes, and runs `pmon` only for the HTML report.

/// What the menu shows, read from the database in one go.
struct Snapshot {
    var index: Int?
    var scores: [(name: String, value: Int)] = []
    var sampleAgeSeconds: Double?
    var busiest: (name: String, cpuPct: Double)?
    var openEpisode: (start: Int64, dominant: String)?
    var lastEpisode: (start: Int64, end: Int64, dominant: String, culprit: String?)?
    var findings = 0

    static let dimensionNames = ["cpu": "CPU contention", "memory": "memory pressure", "disk": "disk saturation",
                                 "thermal": "thermal throttling", "gpu": "GPU saturation", "ui": "an unresponsive app"]

    static func read(_ path: String) -> Snapshot? {
        guard FileManager.default.fileExists(atPath: path), let db = try? Database(path: path, readOnly: true) else { return nil }
        var s = Snapshot()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        try? db.query("""
            SELECT s.ts, y.slug_index, y.s_cpu, y.s_mem, y.s_disk, y.s_thermal, y.s_gpu, y.s_ui
            FROM sample s JOIN sys_sample y USING (sample_id) ORDER BY s.sample_id DESC LIMIT 1
            """) { r in
            s.sampleAgeSeconds = Double(now - r.int(0)) / 1000
            if !r.isNull(1) { s.index = Int(r.int(1)) }
            let names = ["cpu", "memory", "disk", "thermal", "gpu", "ui"]
            s.scores = names.enumerated().compactMap { i, n in r.isNull(2 + i) || r.int(2 + i) == 0 ? nil : (n, Int(r.int(2 + i))) }
                .sorted { $0.value > $1.value }
        }
        // The busiest real app in the latest process sweep.
        try? db.query("""
            SELECT a.name, x.cpu_ms * 100.0 / s.proc_dt_ms FROM app_sample x JOIN sample s USING (sample_id) JOIN app a USING (app_id)
            WHERE s.sample_id = (SELECT MAX(sample_id) FROM sample WHERE proc_dt_ms > 0) AND x.cpu_ms > 0
              AND a.key NOT IN ('pmon.other', 'system.unattributed', 'system.foreign', 'system.machine')
            ORDER BY x.cpu_ms DESC LIMIT 1
            """) { s.busiest = ($0.text(0), $0.double(1)) }
        try? db.query("SELECT start_ts FROM episode WHERE end_ts IS NULL ORDER BY episode_id DESC LIMIT 1") { r in
            // The dominant dimension is only stored when an episode closes: use the current highest score.
            s.openEpisode = (r.int(0), s.scores.first?.name ?? "cpu")
        }
        try? db.query("""
            SELECT e.start_ts, e.end_ts, e.dominant,
                   (SELECT a.name FROM episode_blame b JOIN app a USING (app_id)
                    WHERE b.episode_id = e.episode_id AND b.role = 'culprit' ORDER BY b.score DESC LIMIT 1)
            FROM episode e WHERE e.end_ts IS NOT NULL AND e.dominant IS NOT NULL ORDER BY e.episode_id DESC LIMIT 1
            """) { s.lastEpisode = ($0.int(0), $0.int(1), $0.text(2), $0.optText(3)) }
        s.findings = Int((try? db.scalarInt("SELECT COUNT(*) FROM finding WHERE status = 'open'")) ?? 0)
        return s
    }
}

@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let dbPath: String
    private let pmon: String
    private var timer: Timer?

    init(dbPath: String) {
        self.dbPath = dbPath
        // The command-line tool sits next to this executable.
        pmon = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("pmon").path
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refreshTitle()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refreshTitle() } }
    }

    private static func clock(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(Date(timeIntervalSince1970: Double(ms) / 1000)) ? "HH:mm" : "EEE HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    private var stale: Bool = false

    private func refreshTitle() {
        let s = Snapshot.read(dbPath)
        stale = (s?.sampleAgeSeconds ?? .infinity) > 180
        guard let button = item.button else { return }
        let slow = s?.openEpisode != nil && !stale
        let symbol = stale ? "gauge.with.dots.needle.0percent" : (slow ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.33percent")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "pmon")
            ?? NSImage(systemSymbolName: "speedometer", accessibilityDescription: "pmon")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeading
        button.title = stale ? " –" : " \(s?.index ?? 0)"
        button.toolTip = "pmon: sluggishness index (0 fine, 100 saturated)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshTitle()
        menu.removeAllItems()
        func info(_ text: String) { menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: "")) }
        func action(_ text: String, _ selector: Selector, key: String = "", tag: Int = 0) {
            let m = NSMenuItem(title: text, action: selector, keyEquivalent: key)
            m.target = self
            m.tag = tag
            menu.addItem(m)
        }
        guard let s = Snapshot.read(dbPath) else {
            info("No data yet. Start the daemon with `pmon install`.")
            menu.addItem(.separator()); action("Open dashboard…", #selector(openTab(_:)), key: "d", tag: 0)
            menu.addItem(.separator()); action("Quit pmon menu", #selector(quit), key: "q")
            return
        }
        if stale {
            info("The daemon is not recording (last sample \(Int((s.sampleAgeSeconds ?? 0) / 60)) min ago)")
        } else {
            let parts = s.scores.prefix(3).map { "\($0.name) \($0.value)" }.joined(separator: ", ")
            action("Sluggishness \(s.index ?? 0) of 100" + (parts.isEmpty ? "" : " (\(parts))"), #selector(openLive))
            if let b = s.busiest { action("Busiest: \(b.name), \(String(format: "%.0f", b.cpuPct)) % of a core", #selector(openLive)) }
            if let e = s.openEpisode { action("Slow since \(Self.clock(e.start)): \(Snapshot.dimensionNames[e.dominant] ?? e.dominant)", #selector(explain)) }
        }
        if let e = s.lastEpisode {
            let minutes = max(1, Int((Double(e.end - e.start) / 60_000).rounded()))
            action("Last slowdown: \(Self.clock(e.start)), \(minutes) min, \(Snapshot.dimensionNames[e.dominant] ?? e.dominant)"
                   + (e.culprit.map { " — \($0)" } ?? ""), #selector(explain))
        } else {
            info("No slowdowns recorded")
        }
        menu.addItem(.separator())
        action("Open dashboard…", #selector(openTab(_:)), key: "d", tag: 0)
        action("Live charts…", #selector(openTab(_:)), key: "l", tag: 1)
        action("Explain the latest slowdown…", #selector(explain), key: "e")
        action("Slowdowns…", #selector(openTab(_:)), tag: 2)
        action(s.findings == 0 ? "Findings: none…" : "Findings: \(s.findings) active…", #selector(openTab(_:)), key: "f", tag: 3)
        action("Applications…", #selector(openTab(_:)), tag: 4)
        menu.addItem(.separator())
        action("Open HTML report (last 7 days)", #selector(report))
        menu.addItem(.separator())
        action("Quit pmon menu", #selector(quit), key: "q")
    }

    private var dashboard: DashboardWindow { DashboardWindow.shared(dbPath: dbPath) }

    @objc private func openTab(_ sender: NSMenuItem) {
        dashboard.show([DashboardTab.overview, .live, .slowdowns, .findings, .apps][sender.tag])
    }

    @objc private func openLive() { dashboard.show(.live) }

    /// The open slowdown if there is one, else the latest.
    @objc private func explain() { dashboard.show(.slowdowns, latestEpisode: true) }

    @objc private func report() {
        let out = NSTemporaryDirectory() + "pmon-report.html"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pmon)
        p.arguments = ["report", "--since", "7d", "--output", out, "--db", dbPath]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); p.waitUntilExit() } catch { dashboard.show(.overview); return }
        NSWorkspace.shared.open(URL(fileURLWithPath: out))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

var dbPath = PmonPaths.database
var openAtLaunch: DashboardTab?
enum Selection { case episode(Int64), finding(Int64), app(String) }
var selectAtLaunch: Selection?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--db": if !args.isEmpty { dbPath = args.removeFirst() }
    case "--dashboard":
        // Open the window at launch, optionally on a tab: overview, live, slowdowns, findings, apps.
        // Also accepts episode:<id>, finding:<id> or app:<name> to open with that item selected.
        openAtLaunch = .overview
        if let next = args.first, !next.hasPrefix("--") {
            let parts = next.split(separator: ":", maxSplits: 1).map(String.init)
            switch (parts[0], parts.count > 1 ? parts[1] : nil) {
            case ("episode", let v?): openAtLaunch = .slowdowns; selectAtLaunch = .episode(Int64(v) ?? 0)
            case ("finding", let v?): openAtLaunch = .findings; selectAtLaunch = .finding(Int64(v) ?? 0)
            case ("app", let v?): openAtLaunch = .apps; selectAtLaunch = .app(v)
            default: openAtLaunch = DashboardTab(rawValue: next) ?? .overview
            }
            args.removeFirst()
        }
    case "--snapshot":
        // For checking without a display: print what the menu would show and exit.
        if let s = Snapshot.read(dbPath) {
            print("index \(s.index.map(String.init) ?? "-"), age \(Int(s.sampleAgeSeconds ?? -1)) s, scores \(s.scores.map { "\($0.name)=\($0.value)" })")
            print("busiest \(s.busiest.map { "\($0.name) \(Int($0.cpuPct)) %" } ?? "-"), open \(s.openEpisode != nil), findings \(s.findings)")
            print("last \(s.lastEpisode.map { "\($0.dominant) \($0.culprit ?? "-")" } ?? "-")")
        } else { print("no database at \(dbPath)") }
        exit(0)
    case let a where a.hasPrefix("-Apple") || a.hasPrefix("-NS"):
        // System defaults given on the command line, e.g. -AppleInterfaceStyle Dark; AppKit reads them itself.
        if !args.isEmpty { args.removeFirst() }
    default:
        print("usage: pmon-menu [--db <path>] [--snapshot] [--dashboard [overview|live|slowdowns|findings|apps|episode:<id>|finding:<id>|app:<name>]]")
        exit(2)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)          // no Dock icon, no main menu
// Top-level code runs on the main thread.
let controller = MainActor.assumeIsolated { MenuController(dbPath: dbPath) }
if let tab = openAtLaunch {
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            let w = DashboardWindow.shared(dbPath: dbPath)
            switch selectAtLaunch {
            case .episode(let id): w.show(.slowdowns, episode: id)
            case .finding(let id): w.show(.findings, finding: id)
            case .app(let name): w.show(.apps); w.model.showApp(named: name)
            case nil: w.show(tab)
            }
        }
    }
}
app.run()
