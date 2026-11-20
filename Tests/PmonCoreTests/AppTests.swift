import XCTest
@testable import PmonCore

final class AppResolverTests: XCTestCase {
    func ident(_ pid: Int32, _ path: String, ppid: Int32 = 1, own: Bool = true, responsible: Int32? = nil,
               coalition: UInt64? = nil, bundle: (String, String, String)? = nil) -> ProcIdentity {
        var id = ProcIdentity()
        id.pid = pid; id.uid = UInt64(pid) + 1000; id.ppid = ppid; id.parentUid = UInt64(ppid) + 1000
        id.path = path; id.name = (path as NSString).lastPathComponent; id.own = own
        id.responsiblePid = own ? (responsible ?? pid) : nil
        id.coalitionId = coalition
        if let b = bundle { id.bundlePath = b.0; id.bundleId = b.1; id.bundleName = b.2 }
        return id
    }

    let brave = ("/Applications/Brave Browser.app", "com.brave.Browser", "Brave Browser")
    let terminal = ("/System/Applications/Utilities/Terminal.app", "com.apple.Terminal", "Terminal")
    let safari = ("/Applications/Safari.app", "com.apple.Safari", "Safari")

    /// A realistic process tree: a browser with helpers, a web-content XPC service, a terminal
    /// running a shell and tools, and system processes.
    func tree() -> [ProcIdentity] {
        [
            ident(0, "kernel_task", ppid: 0, own: false),
            ident(1, "/sbin/launchd", ppid: 0, own: false, coalition: 1),
            ident(100, "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser", coalition: 50, bundle: brave),
            ident(101, "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)",
                  ppid: 100, responsible: 100, coalition: 50, bundle: brave),
            ident(200, "/Applications/Safari.app/Contents/MacOS/Safari", coalition: 51, bundle: safari),
            ident(201, "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent",
                  responsible: 200, coalition: 51),
            ident(300, "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", coalition: 60, bundle: terminal),
            ident(301, "/bin/zsh", ppid: 300, responsible: 300, coalition: 60),
            ident(302, "/opt/homebrew/bin/node", ppid: 301, responsible: 300, coalition: 60),
            ident(303, "/usr/bin/sudo", ppid: 301, own: false, coalition: 60),          // root child of the shell: no responsible pid
            ident(304, "/opt/homebrew/bin/redis-server", ppid: 303, own: false),        // its child, no coalition info either
            ident(400, "/usr/libexec/logd", own: false, coalition: 1),
            ident(401, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer", own: false, coalition: 70),
            ident(402, "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock", coalition: 71,
                  bundle: ("/System/Library/CoreServices/Dock.app", "com.apple.dock", "Dock")),
            ident(500, "/Library/PrivilegedHelperTools/com.vendor.helper", own: false, coalition: 80),
            ident(501, "/opt/homebrew/bin/orphan", ppid: 4242),
            ident(502, "/bin/sh", ppid: 400, own: false, coalition: 1),                 // child of a bare system daemon
        ]
    }

    func check(_ result: [UInt64: (app: AppRef, rule: AttributionRule)], file: StaticString = #filePath, line: UInt = #line) {
        func r(_ pid: Int32) -> (app: AppRef, rule: AttributionRule) { result[UInt64(pid) + 1000]! }
        XCTAssertEqual(r(100).app.key, "com.brave.Browser", file: file, line: line); XCTAssertEqual(r(100).rule, .bundle, file: file, line: line)
        XCTAssertEqual(r(100).app.kind, "app", file: file, line: line); XCTAssertEqual(r(100).app.name, "Brave Browser", file: file, line: line)
        XCTAssertEqual(r(101).app.key, "com.brave.Browser", file: file, line: line); XCTAssertEqual(r(101).rule, .responsible, file: file, line: line)
        XCTAssertEqual(r(201).app.key, "com.apple.Safari", "an XPC service outside the bundle follows its responsible app", file: file, line: line)
        XCTAssertEqual(r(301).app.key, "com.apple.Terminal", file: file, line: line)
        XCTAssertEqual(r(302).app.key, "com.apple.Terminal", "a tool run from a terminal belongs to the terminal", file: file, line: line)
        XCTAssertEqual(r(303).app.key, "com.apple.Terminal", file: file, line: line); XCTAssertEqual(r(303).rule, .coalition, file: file, line: line)
        XCTAssertEqual(r(304).app.key, "com.apple.Terminal", file: file, line: line); XCTAssertEqual(r(304).rule, .parent, file: file, line: line)
        XCTAssertEqual(r(0).app.kind, "system", file: file, line: line); XCTAssertEqual(r(0).app.name, "kernel_task", file: file, line: line)
        XCTAssertEqual(r(400).app.key, "/usr/libexec/logd", file: file, line: line); XCTAssertEqual(r(400).app.kind, "system", file: file, line: line)
        XCTAssertEqual(r(400).rule, .exe, "coalition 1 is never used for attribution", file: file, line: line)
        XCTAssertEqual(r(401).app.name, "WindowServer", file: file, line: line); XCTAssertEqual(r(401).app.kind, "system", file: file, line: line)
        XCTAssertEqual(r(402).app.kind, "system", "bundles inside /System/Library are parts of the OS", file: file, line: line)
        XCTAssertEqual(r(500).app.kind, "daemon", file: file, line: line)
        XCTAssertEqual(r(501).app.kind, "cli", file: file, line: line)
        XCTAssertEqual(r(502).rule, .exe, "children of a bare executable do not inherit it", file: file, line: line)
        XCTAssertEqual(r(502).app.key, "/bin/sh", file: file, line: line)
    }

    func testRealisticTree() {
        var resolver = AppResolver()
        check(resolver.resolve(tree()))
    }

    func testOrderWithinABatchDoesNotMatter() {
        for seed in 0..<5 {
            var resolver = AppResolver()
            var batch = tree()
            var g = SystemRandomNumberGenerator()
            _ = seed
            batch.shuffle(using: &g)
            check(resolver.resolve(batch))
        }
    }

    func testLaterProcessesResolveAgainstEarlierOnes() {
        var resolver = AppResolver()
        _ = resolver.resolve(tree())
        let later = resolver.resolve([
            ident(310, "/usr/bin/git", ppid: 301, responsible: 300, coalition: 60),
            ident(311, "/opt/homebrew/bin/python3", ppid: 304, own: false),
            ident(110, "/Applications/Brave Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper", ppid: 100, own: false, bundle: brave),
        ])
        XCTAssertEqual(later[1310]?.app.key, "com.apple.Terminal")
        XCTAssertEqual(later[1311]?.app.key, "com.apple.Terminal"); XCTAssertEqual(later[1311]?.rule, .parent)
        XCTAssertEqual(later[1110]?.app.key, "com.brave.Browser"); XCTAssertEqual(later[1110]?.rule, .bundle)
    }

    func testCyclesAndSelfReferencesTerminate() {
        var resolver = AppResolver()
        var a = ident(10, "/opt/a", ppid: 11), b = ident(11, "/opt/b", ppid: 10)
        a.responsiblePid = 11; b.responsiblePid = 10
        let r = resolver.resolve([a, b])
        XCTAssertEqual(r.count, 2)
    }
}

final class SelectionAndAggregationTests: XCTestCase {
    func testTopKPerDimensionAndFloors() {
        let sel = Selection()
        var c: [Selection.Candidate] = (0..<40).map { Selection.Candidate(uid: UInt64($0), cpuNs: UInt64($0) * 1_000_000, footprint: Int64($0) << 20) }
        c[3].disk = 9 << 20                    // disk floor and top disk
        c[7].growth = 30 << 20                 // growth floor and top growth
        c[11].wakeups = 5000; c[12].pageins = 800
        c[20].isSelf = true
        c.append(Selection.Candidate(uid: 99, cpuNs: 900_000_000))      // 9 % of a core over 10 s
        let r = sel.select(c, dtMs: 10_000)
        XCTAssertEqual(r[99]?.contains([.topCpu, .floor]), true)
        XCTAssertEqual(r[39]?.contains([.topCpu, .topFootprint]), true)
        XCTAssertEqual(r[3], [.topDisk, .floor]); XCTAssertEqual(r[7], [.topGrowth, .floor])
        XCTAssertEqual(r[11], [.topWakeups]); XCTAssertEqual(r[12], [.topPageins])
        XCTAssertEqual(r[20], [.selfProcess])
        XCTAssertNil(r[1], "an unremarkable process gets no row")
        XCTAssertLessThanOrEqual(r.count, 5 * 6 + 2)
        XCTAssertNil(sel.select([Selection.Candidate(uid: 1)], dtMs: 10_000)[1], "zero is never a top value")
    }

    func testSlicesAddUpExactly() {
        var a = AppAgg()
        a.cpuMs = 1001; a.dFootprint = -7; a.pageins = 2; a.footprint = 500; a.procCount = 3
        let ticks: [(id: Int64, start: UInt64, end: UInt64)] = [(1, 0, 10), (2, 10, 20), (3, 20, 30)]
        let slices = Pipeline.slices(of: (2, 29), over: ticks, current: 3)
        XCTAssertEqual(slices.map(\.id), [1, 2, 3])
        let parts = slices.map { a.slice(from: $0.from, to: $0.to) }
        XCTAssertEqual(parts.reduce(0) { $0 + $1.cpuMs! }, 1001)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.dFootprint! }, -7)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.pageins! }, 2)
        XCTAssertEqual(slices.map(\.gauges), [true, true, false], "the last tick ends after the window: its gauges come with the next one")
        let gauged = zip(slices, parts).map { a.slice(from: $0.0.from, to: $0.0.to, gauges: $0.0.gauges) }
        XCTAssertEqual(gauged.map(\.footprint), [500, 500, nil]); XCTAssertEqual(gauged.map(\.procCount), [3, 3, 0])
        XCTAssertGreaterThan(parts[1].cpuMs!, parts[0].cpuMs!, "the middle tick is fully covered, the first only partly")
        // A window that starts before the oldest known tick is shared among the known ones.
        XCTAssertEqual(Pipeline.slices(of: (0, 30), over: [(3, 20, 30)], current: 3).map(\.id), [3])
        XCTAssertEqual(Pipeline.slices(of: nil, over: ticks, current: 3).count, 1)
        XCTAssertEqual(Pipeline.slices(of: (100, 200), over: ticks, current: 3).map(\.id), [3], "no overlap: credit the current tick")
    }

    func testCadencePolicy() {
        let p = CadencePolicy(config: Config())
        XCTAssertEqual(p.decide(session: nil).name, "normal")
        var s = SessionReading()
        XCTAssertEqual(p.decide(session: s).systemSeconds, 5)
        s.idleSeconds = 400
        XCTAssertEqual(p.decide(session: s).name, "relaxed"); XCTAssertEqual(p.decide(session: s).processSeconds, 30)
        XCTAssertFalse(p.decide(session: s).pauseTop)
        s.idleSeconds = 1; s.onBattery = true; s.lowPower = true
        XCTAssertEqual(p.decide(session: s).name, "relaxed")
        s.lowPower = false
        XCTAssertEqual(p.decide(session: s).name, "normal", "battery alone does not slow sampling")
        s.displayOn = false
        XCTAssertEqual(p.decide(session: s).name, "asleep"); XCTAssertTrue(p.decide(session: s).pauseTop)
        XCTAssertEqual(p.decide(session: s).systemSeconds, 60)
        s.displayOn = true; s.locked = true
        XCTAssertEqual(p.decide(session: s).level, 2)
    }
}

final class DiagReportTests: XCTestCase {
    func testParsesDiagHeader() {
        let head = """
            Date/Time:        2026-11-13 21:43:36.794 +0100
            End time:         2026-11-13 21:45:13.957 +0100
            OS Version:       macOS 26.2 (Build 25C56)

            Command:          ANECompilerService
            Path:             /System/Library/PrivateFrameworks/AppleNeuralEngine.framework/XPCServices/ANECompilerService.xpc/Contents/MacOS/ANECompilerService
            Event:            cpu usage
            Duration:         97.16s
            """
        let note = DiagReportWatcher.parse(fileName: "ANECompilerService_2026-11-13-214514_Mac.cpu_resource.diag", head: head)
        XCTAssertEqual(note?.kind, "diag_report")
        XCTAssertEqual(note?.procName, "ANECompilerService")
        XCTAssertTrue(note?.exePath?.hasSuffix("/ANECompilerService") ?? false)
        XCTAssertTrue(note?.detail?.contains(#""event":"cpu usage""#) ?? false)
    }

    func testParsesCrashSummaryAndHang() {
        let ips = #"{"app_name":"xctest","timestamp":"2026-11-20 17:43:35.00 +0100","bug_type":"309","name":"xctest"}"# + "\n{\n  \"uptime\" : 10000\n"
        let crash = DiagReportWatcher.parse(fileName: "xctest-2026-11-20-174335.ips", head: ips)
        XCTAssertEqual(crash?.kind, "crash"); XCTAssertEqual(crash?.procName, "xctest")
        let hang = DiagReportWatcher.parse(fileName: "Safari_2026-11-20-101010_Mac.hang", head: "Command:  Safari\nPath:  /Applications/Safari.app/Contents/MacOS/Safari\n")
        XCTAssertEqual(hang?.kind, "hang"); XCTAssertEqual(hang?.exePath, "/Applications/Safari.app/Contents/MacOS/Safari")
        XCTAssertNil(DiagReportWatcher.parse(fileName: "x.diag", head: "nothing useful here"))
        XCTAssertNil(DiagReportWatcher.parse(fileName: "x.ips", head: "not json"))
    }

    func testWatcherPicksUpNewReports() throws {
        let dir = tempDir(self)
        let w = DiagReportWatcher(directories: [dir])
        w.settleSeconds = 0.2
        w.start()
        Thread.sleep(forTimeInterval: 0.5)
        try "Command:  Safari\nPath:  /Applications/Safari.app/Contents/MacOS/Safari\nEvent:  wakeups\n"
            .write(toFile: dir + "/Safari_2026-11-20.wakeups_resource.diag", atomically: false, encoding: .utf8)
        try "ignored".write(toFile: dir + "/notes.txt", atomically: false, encoding: .utf8)
        var notes: [CollectorNote] = []
        let end = Date().addingTimeInterval(8)
        while notes.isEmpty, Date() < end { Thread.sleep(forTimeInterval: 0.1); notes += w.takeNotes() }
        w.stop()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.procName, "Safari")
    }

    func testSessionCollectorReadsPlausibleValues() {
        let r = SessionCollector().collect()
        XCTAssertGreaterThanOrEqual(r.idleSeconds, 0)
        XCTAssertTrue((0...3).contains(r.thermalLevel))
        if let pid = r.frontPid { XCTAssertGreaterThan(pid, 0) }
    }
}

final class AppPipelineTests: XCTestCase {
    typealias Rig = ProcessPipelineTests.Rig
    typealias FakeTop = ForeignPipelineTests.FakeTop

    let editor = ("/Applications/Editor.app", "com.example.editor", "Editor")
    let browser = ("/Applications/Browser.app", "com.example.browser", "Browser")

    /// Editor (pid 10) with a helper (pid 11), Browser (pid 20), a bare tool (pid 30) and 12 idle tools.
    func makeRig() -> (Rig, editor: UInt64, helper: UInt64, browser: UInt64, tool: UInt64) {
        let rig = Rig()
        rig.fake.bundles = [10: editor, 11: editor, 20: browser]
        rig.fake.responsible = [11: 10]
        rig.fake.parents = [11: 10]
        let e = rig.fake.spawn(pid: 10, footprint: 300 << 20), h = rig.fake.spawn(pid: 11, footprint: 80 << 20)
        let b = rig.fake.spawn(pid: 20, footprint: 500 << 20), t = rig.fake.spawn(pid: 30, footprint: 10 << 20)
        for pid in 40..<52 { rig.fake.spawn(pid: Int32(pid), footprint: 2 << 20) }
        return (rig, e, h, b, t)
    }

    func appId(_ db: Database, _ key: String) throws -> Int64? { try db.scalarInt("SELECT app_id FROM app WHERE key = ?", [key]) }

    func testProcessesAreGroupedIntoApps() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let (rig, e, h, b, t) = makeRig()
        try pipeline.ingest(rig.tick())
        try pipeline.ingest(rig.tick())
        try pipeline.ingest(rig.tick { f in f.run(e, cpuMs: 1000, growMB: 5, diskMB: 2); f.run(h, cpuMs: 500); f.run(b, cpuMs: 200); f.run(t, cpuMs: 60) })

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM app WHERE kind = 'app'"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process p JOIN app a USING (app_id) WHERE a.key = 'com.example.editor'"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE attribution = 'responsible'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process p JOIN app a USING (app_id) WHERE a.key = 'pmon.unresolved'"), 0)

        try db.query("""
            SELECT x.proc_count, x.cpu_ms, x.footprint, x.d_footprint, x.d_disk_write, x.cpu_fg_ms, x.fidelity, x.is_focus
            FROM app_sample x JOIN app a USING (app_id) WHERE a.key = 'com.example.editor'
            """) { r in
            XCTAssertEqual(r.int(0), 2); XCTAssertEqual(r.int(1), 1500); XCTAssertEqual(r.int(2), 385 << 20)
            XCTAssertEqual(r.int(3), 5 << 20); XCTAssertEqual(r.int(4), 2 << 20); XCTAssertEqual(r.int(5), 1500)
            XCTAssertEqual(r.int(6), 0); XCTAssertEqual(r.int(7), 0)
        }
        // The bare tool used 0.6 % of a core: its own row. The 12 idle tools are merged into one.
        XCTAssertEqual(try db.scalarInt("SELECT x.cpu_ms FROM app_sample x JOIN app a USING (app_id) WHERE a.key = '/opt/tools/fake30'"), 60)
        try db.query("SELECT x.proc_count, x.footprint, x.cpu_ms FROM app_sample x JOIN app a USING (app_id) WHERE a.key = 'pmon.other'") { r in
            XCTAssertEqual(r.int(0), 12); XCTAssertEqual(r.int(1), 24 << 20); XCTAssertEqual(r.int(2), 0)
        }
        // App rows are complete: they add up to everything the readable processes did.
        XCTAssertEqual(try db.scalarInt("SELECT SUM(cpu_ms) FROM app_sample WHERE fidelity = 0"), 1760)
        XCTAssertEqual(try db.scalarInt("SELECT SUM(proc_count) FROM app_sample WHERE fidelity = 0"), 16)
        // Disk the readable processes did not do is credited to the combined system row.
        XCTAssertEqual(try db.scalarInt("SELECT x.d_disk_write FROM app_sample x JOIN app a USING (app_id) WHERE a.key = 'system.foreign'"),
                       2 * (2 << 20) - (2 << 20), "device wrote 4 MB in 10 s, the editor accounts for 2 MB")
    }

    func testAppRowsAddUpToSystemBusyCpuIncludingLateTopData() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        rig.fake.bundles = [10: editor]
        let own = rig.fake.spawn(pid: 10)
        var top = FakeTop()
        for i in 0..<14 {                                   // 0 ... 65 s; top samples at 0, 30, 60, each 3 s old
            var rec = rig.tick { $0.run(own, cpuMs: i == 0 ? 0 : 2000) }
            if i > 0 { top.advance(seconds: 5) }
            if rec.procs != nil, i % 6 == 0 {
                var past = top
                past.cpuMs[1]! -= 900; past.cpuMs[88]! -= 60
                rec.top = past.sample(at: rec.tick.monoNs - 3_000_000_000)
            }
            try pipeline.ingest(rec)
        }
        // FakeMachine is busy 1000 ms per second. The second top window (27 s ... 57 s) is fully
        // covered by system totals: own 12000 + foreign 9600 + unexplained 8400 = 30000 ms.
        // The first window's foreign CPU is also credited (its unexplained part is unknown).
        let total = try db.scalarInt("SELECT SUM(cpu_ms) FROM app_sample") ?? 0
        XCTAssertEqual(total, 6 * 4000 + 2 * 9600 + 8400)
        // launchd (pid 1) is attributed to its own system app and its CPU is spread over three ticks.
        try db.query("""
            SELECT COUNT(*), SUM(x.cpu_ms), MIN(x.footprint), MAX(x.footprint), MAX(x.fidelity), a.kind, COUNT(x.footprint), MAX(x.proc_count)
            FROM app_sample x JOIN app a USING (app_id) WHERE a.key = '/sbin/launchd'
            """) { r in
            XCTAssertEqual(r.int(0), 6, "ticks ending at 10 ... 60 s"); XCTAssertEqual(r.int(1), 2 * 9000)
            XCTAssertGreaterThan(r.int(2), 200 << 20)
            XCTAssertLessThan(r.int(3), 260 << 20, "a tick that straddles two windows gets its footprint once, not twice")
            XCTAssertEqual(r.int(4), 1); XCTAssertEqual(r.text(5), "system")
            XCTAssertEqual(r.int(6), 5, "the newest tick gets its gauges with the next top sample")
            XCTAssertEqual(r.int(7), 1)
        }
        // Per tick, the split follows the overlap: the window ends 3 s before the tick that received it.
        var perTick: [Int64] = []
        try db.query("SELECT x.cpu_ms FROM app_sample x JOIN app a USING (app_id) WHERE a.key = '/sbin/launchd' ORDER BY x.sample_id") { perTick.append($0.int(0)) }
        // The second window (27 s ... 57 s) overlaps four ticks by 3, 10, 10 and 7 seconds.
        XCTAssertEqual(Array(perTick.suffix(3)), [3000, 3000, 2100])
        XCTAssertGreaterThan(perTick[perTick.count - 4], 900, "the tick ending at 30 s gets a share of both windows")
        XCTAssertEqual(try db.scalarInt("SELECT SUM(x.cpu_ms) FROM app_sample x JOIN app a USING (app_id) WHERE a.key = 'system.unattributed'"), 8400)
    }

    func testFocusSpansEventsAndContext() throws {
        let path = tempDir(self) + "/a.db"
        let db = try Database(path: path)
        let pipeline = try Pipeline(db: db, host: testHost())
        let (rig, _, _, _, _) = makeRig()
        func session(front: Int32?, idle: Double = 2) -> SessionReading {
            var s = SessionReading(); s.frontPid = front; s.idleSeconds = idle; return s
        }
        var ts: [Int64] = []
        func step(_ s: SessionReading, _ mutate: (inout TickRecord) -> Void = { _ in }) throws {
            var rec = rig.tick()
            rec.session = s
            mutate(&rec)
            ts.append(rec.tick.wallMs)
            try pipeline.ingest(rec)
        }
        try step(session(front: 10))                                   // 0: Editor in front (initial state: no event)
        try step(session(front: 10))
        try step(session(front: 11))                                   // helper window: still Editor
        try step(session(front: 20))                                   // 3: Browser
        try step(session(front: 20)) { $0.system!.pressureLevel = 2 }   // 4: memory pressure warn
        var onBattery = session(front: nil, idle: 500); onBattery.onBattery = true; onBattery.displayOn = false
        try step(onBattery)                                             // 5: nothing in focus, display off, on battery
        try step(onBattery)

        let editorId = try appId(db, "com.example.editor"), browserId = try appId(db, "com.example.browser")
        var spans: [[Int64?]] = []
        try db.query("SELECT start_ts, end_ts, app_id FROM focus_span ORDER BY start_ts") { spans.append([$0.int(0), $0.optInt(1), $0.int(2)]) }
        XCTAssertEqual(spans, [[ts[0], ts[3], editorId], [ts[3], ts[5], browserId]])

        func events(_ kind: String) throws -> [Int64?] {
            var v: [Int64?] = []
            try db.query("SELECT COALESCE(value, app_id) FROM event WHERE kind = ? ORDER BY event_id", [kind]) { v.append($0.optInt(0)) }
            return v
        }
        XCTAssertEqual(try events("focus"), [browserId, nil], "a switch to another process of the same app is not a focus change")
        XCTAssertEqual(try events("pressure"), [2, 1], "warn, then back to normal on the next tick"); XCTAssertEqual(try events("power"), [1]); XCTAssertEqual(try events("display"), [0])
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM event WHERE kind IN ('proc_start', 'proc_exit')"), 0)

        try db.query("SELECT focus_app_id, user_idle_s, display_on, on_battery, screen_locked FROM sys_sample ORDER BY sample_id DESC LIMIT 1") { r in
            XCTAssertTrue(r.isNull(0)); XCTAssertEqual(r.int(1), 500); XCTAssertEqual(r.int(2), 0); XCTAssertEqual(r.int(3), 1); XCTAssertEqual(r.int(4), 0)
        }
        XCTAssertEqual(try db.scalarInt("SELECT focus_app_id FROM sys_sample ORDER BY sample_id LIMIT 1"), editorId)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM app_sample WHERE is_focus = 1 AND app_id = ?", [editorId]), 1,
                       "the focused app has a row on the process tick even when idle")

        // A new run starts with the Browser in front: the span is opened fresh, nothing is left dangling.
        let rig2 = makeRig().0
        let pipeline2 = try Pipeline(db: Database(path: path), host: testHost())
        var rec = rig2.tick(); rec.session = session(front: 20)
        try pipeline2.ingest(rec)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM focus_span WHERE end_ts IS NULL"), 1)
    }

    func testLaunchQuitWakeAndDiagnosticEvents() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let (rig, _, _, b, _) = makeRig()
        try pipeline.ingest(rig.tick())
        try pipeline.ingest(rig.tick())
        rig.fake.bundles[60] = ("/Applications/Chat.app", "com.example.chat", "Chat")
        try pipeline.ingest(rig.tick { f in f.spawn(pid: 60, startNs: rig.clock.monotonicNs - 1_000_000_000); f.kill(b) })
        var rec = rig.tick()
        rec.notes = [CollectorNote(kind: "diag_report", detail: #"{"event":"cpu usage"}"#, exePath: "/Applications/Editor.app/Contents/MacOS/fake10", procName: "fake10"),
                     CollectorNote(kind: "hang", detail: nil, exePath: nil, procName: "no-such-process")]
        try pipeline.ingest(rec)
        rig.clock.sleep(seconds: 1800)
        try pipeline.ingest(rig.tick())

        XCTAssertEqual(try db.scalarInt("SELECT app_id FROM event WHERE kind = 'proc_start'"), try appId(db, "com.example.chat"))
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM event WHERE kind = 'proc_start'"), 1, "only the app launched during the run")
        XCTAssertEqual(try db.scalarInt("SELECT app_id FROM event WHERE kind = 'proc_exit'"), try appId(db, "com.example.browser"))
        XCTAssertEqual(try db.scalarInt("SELECT app_id FROM event WHERE kind = 'diag_report'"), try appId(db, "com.example.editor"))
        XCTAssertNotNil(try db.scalarInt("SELECT proc_id FROM event WHERE kind = 'diag_report'"))
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM event WHERE kind = 'hang' AND app_id IS NULL"), 1, "an unknown process still yields an event")
        XCTAssertEqual(try db.scalarInt("SELECT value FROM event WHERE kind = 'wake'"), 1800)
    }

    func testReplayWithAppsAndSessionIsIdentical() throws {
        let dir = tempDir(self)
        let live = try Database(path: dir + "/live.db")
        let pipeline = try Pipeline(db: live, host: testHost())
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost())
        let (rig, e, h, b, _) = makeRig()
        var top = FakeTop()
        for i in 0..<20 {
            var rec = rig.tick { f in f.run(e, cpuMs: 700, growMB: 1); f.run(h, cpuMs: 50); if i < 9 { f.run(b, cpuMs: 300) }; if i == 9 { f.kill(b) } }
            if i > 0 { top.advance(seconds: 5) }
            if rec.procs != nil, i % 6 == 0 { rec.top = top.sample(at: rec.tick.monoNs - 2_000_000_000) }
            var s = SessionReading(); s.frontPid = i < 8 ? 10 : (i < 9 ? 20 : nil); s.idleSeconds = Double(i); s.onBattery = i > 12
            rec.session = s
            if i == 15 { rec.notes = [CollectorNote(kind: "cadence", value: 1, detail: #"{"mode":"relaxed"}"#)] }
            try recorder.append(rec); try pipeline.ingest(rec)
        }
        recorder.close()
        let replayed = try Database(path: dir + "/replay.db")
        try Replayer.replay(recording: dir + "/run.jsonl", into: replayed)
        for (table, order) in [("sample", "sample_id"), ("sys_sample", "sample_id"), ("proc_sample", "sample_id, proc_id"),
                               ("app_sample", "sample_id, app_id"), ("app", "app_id"), ("process", "proc_id"),
                               ("focus_span", "start_ts"), ("event", "event_id")] {
            let x = try dump(live, table, orderBy: order), y = try dump(replayed, table, orderBy: order)
            XCTAssertFalse(x.isEmpty, table)
            XCTAssertEqual(x, y, "\(table) differs between live run and replay")
        }
    }
}
