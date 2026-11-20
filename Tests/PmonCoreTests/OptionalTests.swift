import XCTest
@testable import PmonCore

final class CaptureFrameworkTests: XCTestCase {
    func testBudgetUnderABurstOfEpisodes() {
        var b = CaptureBudget(maxPerHour: 6, minBatteryPct: 20)
        // Twenty episodes in twenty minutes: only the first six get a capture set.
        let granted = (1...20).filter { b.allow(episodeId: Int64($0), nowMs: Int64($0) * 60_000, onBattery: false, batteryPct: nil) }
        XCTAssertEqual(granted, [1, 2, 3, 4, 5, 6])
        XCTAssertFalse(b.allow(episodeId: 1, nowMs: 21 * 60_000, onBattery: false, batteryPct: nil), "one set per episode")
        // An hour after the first grants, room again.
        XCTAssertTrue(b.allow(episodeId: 30, nowMs: 62 * 60_000, onBattery: false, batteryPct: nil))
        XCTAssertTrue(b.allow(episodeId: 31, nowMs: 63 * 60_000, onBattery: false, batteryPct: nil))
        // By minute 63 the grants of minutes 1 to 3 have aged out: 4, 5, 6, 30 and 31 remain.
        XCTAssertTrue(b.allow(episodeId: 32, nowMs: 63 * 60_000 + 1, onBattery: false, batteryPct: nil))
        XCTAssertFalse(b.allow(episodeId: 33, nowMs: 63 * 60_000 + 2, onBattery: false, batteryPct: nil), "six within the last hour again")
    }

    func testBudgetBatteryGuard() {
        var b = CaptureBudget(maxPerHour: 6, minBatteryPct: 20)
        XCTAssertFalse(b.allow(episodeId: 1, nowMs: 0, onBattery: true, batteryPct: 12))
        XCTAssertFalse(b.allow(episodeId: 1, nowMs: 1, onBattery: false, batteryPct: 12), "an episode gets one chance")
        XCTAssertTrue(b.allow(episodeId: 2, nowMs: 2, onBattery: true, batteryPct: 55))
        XCTAssertTrue(b.allow(episodeId: 3, nowMs: 3, onBattery: false, batteryPct: 5), "on mains the level does not matter")
    }

    func testCollectorConfigDefaultsAndPartialJson() throws {
        let d = Config()
        XCTAssertEqual(d.collectors.gpu, .always)
        for name in CollectorConfig.names where name != "gpu" { XCTAssertEqual(d.collectors[name], .off, name) }
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"collectors":{"stack":"triggered","maxCaptureSetsPerHour":2}}"#.utf8))
        XCTAssertEqual(c.collectors.stack, .triggered); XCTAssertEqual(c.collectors.threads, .off)
        XCTAssertEqual(c.collectors.maxCaptureSetsPerHour, 2); XCTAssertEqual(c.collectors.minBatteryPct, 20)
        var m = CollectorConfig(); m["footprint"] = .always
        XCTAssertEqual(m.footprint, .always); XCTAssertNil(m["nonsense"])
    }

    func testSampleSummarySkipsWaitingFrames() {
        let text = """
            Call graph:
                3228 Thread_1   DispatchQueue_1: com.apple.main-thread  (serial)

            Sort by top of stack, same collapsed (when >= 5):
                    partial apply for closure #1 in Cpu.run()  (in pmon-stress)        3000
                    __ulock_wait  (in libsystem_kernel.dylib)        1614
                    szone_malloc  (in libsystem_malloc.dylib)        1000

            Binary Images:
                   0x104cf0000 -        0x104e1f31f +pmon-stress (0)
            """
        XCTAssertEqual(CaptureSummary.hotFrames(sampleOutput: text),
                       ["partial apply for closure #1 in Cpu.run() (pmon-stress) 75 %", "szone_malloc (libsystem_malloc.dylib) 25 %"])
        XCTAssertEqual(CaptureSummary.hotFrames(sampleOutput: "nothing useful"), [])
    }

    func testFootprintAndNetworkSummaries() {
        let fp = """
            zsh [93448]: 64-bit    Footprint: 1601 KB (16384 bytes per page)

              Dirty      Clean  Reclaimable    Regions    Category
                ---        ---          ---        ---    ---
             432 KB        0 B          0 B          5    MALLOC_SMALL
             304 KB        0 B          0 B         10    MALLOC metadata
                0 B     544 KB          0 B         50    __TEXT
                ---        ---          ---        ---    ---
            1601 KB     592 KB          0 B        410    TOTAL
            """
        XCTAssertEqual(CaptureSummary.footprintCategories(fp), ["MALLOC_SMALL 432 KB", "MALLOC metadata 304 KB"])
        let net = """
            ,bytes_in,bytes_out,
            Safari.500,999999,999999,
            ,bytes_in,bytes_out,
            mDNSResponder.483,1650,532,
            Brave Browser H.832,204800,0,
            idle.9,0,0,
            """
        XCTAssertEqual(CaptureSummary.networkTalkers(net, seconds: 2), ["Brave Browser H 100 KB/s", "mDNSResponder 1 KB/s"])
    }
}

/// Tests that read the live machine.
final class OptionalCollectorLiveTests: XCTestCase {
    func testGpuReadings() {
        let gpu = GpuCollector()
        if let u = gpu.utilisation() { XCTAssertTrue((0...100).contains(u)) }
        for c in gpu.clients() { XCTAssertGreaterThan(c.pid, 0) }
        XCTAssertEqual(GpuCollector.pid(fromCreator: "pid 410, WindowServer"), 410)
        XCTAssertNil(GpuCollector.pid(fromCreator: "kernel"))
    }

    func testProcessProbeOnOwnProcess() {
        let threads = ProcessProbe.threads(pid: getpid())
        XCTAssertFalse(threads.isEmpty)
        XCTAssertGreaterThan(ProcessProbe.openFiles(pid: getpid()) ?? 0, 2)
        XCTAssertTrue(ProcessProbe.arguments(pid: getpid())?.contains("xctest") ?? false)
        XCTAssertNil(ProcessProbe.arguments(pid: 1), "another user's process is not readable")
    }

    func testDiskProbe() {
        let probe = DiskProbe(path: tempDir(self) + "/probe.bin")
        XCTAssertGreaterThan(probe.measure() ?? 0, 0)
        XCTAssertGreaterThan(probe.measure() ?? 0, 0, "the scratch file is reused")
    }

    func testScanFindsShortLivedChildren() {
        let spawner = Thread {
            for _ in 0..<12 {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sleep")
                p.arguments = ["0.15"]
                try? p.run()
                p.waitUntilExit()
            }
        }
        spawner.start()
        let scan = ShortLivedScanner.scan(seconds: 3, intervalMs: 20)
        XCTAssertGreaterThanOrEqual(scan.births, 8)
        let mine = scan.groups.first { $0.name == "sleep" && $0.parentPid == getpid() }
        XCTAssertNotNil(mine, "\(scan.groups)")
        XCTAssertGreaterThanOrEqual(mine?.count ?? 0, 8)
        XCTAssertGreaterThan(mine?.sightings ?? 0, 30, "each lives about 150 ms: several sightings at 20 ms")
        XCTAssertTrue((800...3000).contains(mine?.aliveMs ?? 0), "about 12 x 150 ms, got \(mine?.aliveMs ?? 0)")
        XCTAssertTrue((2900...3400).contains(scan.durationMs), "bounded by time, got \(scan.durationMs)")
        XCTAssertEqual(mine?.path, "/bin/sleep")
    }

    func testCapturesOfAChildProcess() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        defer { child.terminate() }
        var config = CollectorConfig(); config.stack = .always; config.threads = .always; config.footprint = .always
        let m = CaptureManager(dir: tempDir(self) + "/captures", config: config)
        let t = CaptureTarget(pid: child.processIdentifier, name: "yes", cpuShare: 0.9, footprint: 1 << 20)
        m.submit(CaptureRequest(episodeId: 7, ts: 1000, dominant: "memory", cpuTop: [t], memTop: [t]), onBattery: false, batteryPct: nil)
        var got: [CaptureResult] = []
        let deadline = Date().addingTimeInterval(30)
        while got.count < 3, Date() < deadline { got += m.take(); usleep(200_000) }
        XCTAssertEqual(Set(got.map(\.kind)), ["stack", "procs", "footprint"])
        for c in got {
            XCTAssertEqual(c.episodeId, 7)
            XCTAssertTrue(c.path.hasSuffix(".gz")); XCTAssertTrue(FileManager.default.fileExists(atPath: c.path), c.path)
            XCTAssertGreaterThan(c.bytes, 0); XCTAssertTrue(c.summary.hasPrefix("yes: "), c.summary)
        }
        XCTAssertTrue(got.first { $0.kind == "procs" }!.summary.contains("busiest"), "yes spins: its thread shows up")
        // The same episode is not captured twice.
        m.submit(CaptureRequest(episodeId: 7, ts: 2000, dominant: "cpu", cpuTop: [t], memTop: [t]), onBattery: false, batteryPct: nil)
        usleep(1_500_000)
        XCTAssertTrue(m.take().isEmpty)
    }
}

final class OptionalPipelineTests: XCTestCase {
    typealias Rig = ProcessPipelineTests.Rig

    func appId(_ db: Database, _ key: String) throws -> Int64? { try db.scalarInt("SELECT app_id FROM app WHERE key = ?", [key]) }

    /// The GPU is saturated for a minute; Renderer (pid 10) uses most of the GPU time.
    func runGpuScenario(db: Database, recorder: Recorder? = nil) throws -> [CaptureRequest] {
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        rig.fake.bundles = [10: ("/Applications/Renderer.app", "com.example.renderer", "Renderer"), 20: ("/Applications/Other.app", "com.example.other", "Other")]
        let renderer = rig.fake.spawn(pid: 10), other = rig.fake.spawn(pid: 20)
        var gpu: [Int32: UInt64] = [10: 5_000_000_000, 20: 1_000_000_000, 88: 7_000_000_000]
        var requests: [CaptureRequest] = []
        for i in 0..<50 {
            let hot = (8..<20).contains(i)
            var rec = rig.tick { f in f.run(renderer, cpuMs: hot ? 900 : 50); f.run(other, cpuMs: 50) }
            rec.system?.gpuUtilPct = hot ? 100 : 12
            if hot { gpu[10]! += 4_000_000_000; gpu[20]! += 500_000_000 }       // per 5 s tick
            if rec.procs != nil { rec.gpu = gpu.map { GpuClient(pid: $0.key, ns: $0.value) }.sorted { $0.pid < $1.pid } }
            if i == 14 {
                rec.captures = [CaptureResult(episodeId: 1, kind: "stack", pid: 10, path: "/tmp/x.txt.gz", bytes: 1234, summary: "Renderer: draw 90 %", costMs: 3400)]
            }
            var s = SessionReading(); s.frontPid = 10; s.idleSeconds = 3
            rec.session = s
            try recorder?.append(rec)
            try pipeline.ingest(rec)
            if let r = pipeline.takeCaptureRequest() { requests.append(r) }
        }
        return requests
    }

    func testGpuEpisodeIsScoredBlamedAndRequestsACapture() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let requests = try runGpuScenario(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE dominant = 'gpu' AND m_gpu > 80"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(gpu_util_pct) FROM sys_sample"), 100)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(s_gpu) FROM sys_sample"), 100)

        // GPU time lands on the apps: 12 hot ticks of 4 s and 0.5 s.
        let renderer = try appId(db, "com.example.renderer"), other = try appId(db, "com.example.other")
        XCTAssertEqual(try db.scalarInt("SELECT SUM(d_gpu_ms) FROM app_sample WHERE app_id = ?", [renderer]), 48_000)
        XCTAssertEqual(try db.scalarInt("SELECT SUM(d_gpu_ms) FROM app_sample WHERE app_id = ?", [other]), 6_000)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM app_sample WHERE d_gpu_ms IS NOT NULL AND app_id NOT IN (?, ?)", [renderer, other]), 0,
                       "a client that used no GPU time gets no row")

        try db.query("SELECT share, role, detail FROM episode_blame WHERE dim = 'gpu' AND app_id = ?", [renderer]) { r in
            XCTAssertEqual(r.double(0), 0.8889, accuracy: 0.01); XCTAssertEqual(r.text(1), "culprit"); XCTAssertTrue(r.text(2).contains("gpu_pct"))
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode_blame WHERE dim = 'gpu'"), 2)

        // One capture request, naming the busiest readable process first.
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.episodeId, 1); XCTAssertEqual(requests.first?.dominant, "gpu")
        XCTAssertEqual(requests.first?.cpuTop.first?.pid, 10)
        XCTAssertEqual(requests.first?.cpuTop.first?.cpuShare ?? 0, 0.18, accuracy: 0.01)
        XCTAssertFalse(requests.first!.cpuTop.contains { $0.pid == 77 }, "the daemon does not capture itself")

        // The finished capture is stored against the episode and the process.
        try db.query("SELECT c.episode_id, c.kind, c.bytes, c.summary, c.cost_ms, p.pid FROM capture c JOIN process p USING (proc_id)") { r in
            XCTAssertEqual(r.int(0), 1); XCTAssertEqual(r.text(1), "stack"); XCTAssertEqual(r.int(2), 1234)
            XCTAssertEqual(r.text(3), "Renderer: draw 90 %"); XCTAssertEqual(r.int(4), 3400); XCTAssertEqual(r.int(5), 10)
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM capture"), 1)
    }

    func testNoGpuReadingMeansNoGpuScore() throws {
        var scorer = Scorer()
        XCTAssertNil(scorer.score(ScoreInput()).gpu)
        var x = ScoreInput(); x.gpuUtilPct = 100
        XCTAssertEqual(scorer.score(x).gpu, 100, "the history starts afresh after a gap")
        x.gpuUtilPct = 60
        XCTAssertEqual(scorer.score(x).gpu, 0)
        x.gpuUtilPct = 100
        XCTAssertEqual(scorer.score(x).gpu, 100, "median of 100, 60, 100")
        x.gpuUtilPct = 84
        XCTAssertEqual(scorer.score(x).gpu, 50, "median of 60, 100, 84")
    }

    /// CPU is busy but no process accounts for it; a scan finds that Builder (pid 10) keeps
    /// starting short-lived compilers.
    func runChurnScenario(db: Database, recorder: Recorder? = nil, withScan: Bool) throws -> [Double] {
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        rig.fake.bundles = [10: ("/Applications/Builder.app", "com.example.builder", "Builder"), 20: ("/Applications/Editor.app", "com.example.editor", "Editor")]
        let builder = rig.fake.spawn(pid: 10), editor = rig.fake.spawn(pid: 20)
        var shares: [Double] = []
        var foreignNs: UInt64 = 1_000_000_000
        for i in 0..<50 {
            let hot = (8..<20).contains(i)
            var rec = rig.tick { f in
                f.run(builder, cpuMs: 100)
                f.run(editor, cpuMs: 100, waitMs: hot ? 20_000 : 0)        // the editor cannot get a core
            }
            if rec.procs != nil {
                foreignNs += 200_000_000
                rec.ps = PsSample(monoNs: rec.tick.monoNs, rows: [PsRow(pid: 1, userNs: foreignNs, sysNs: 0), PsRow(pid: 88, userNs: foreignNs, sysNs: 0)])
            }
            if withScan, i == 13 {
                rec.shortLived = ShortLivedScan(durationMs: 10_000, intervalMs: 50, births: 420, costCpuMs: 31, groups: [
                    ShortLivedGroup(path: "/usr/bin/clang", name: "clang", parentPid: 10, parentName: "Builder", count: 400, sightings: 160, aliveMs: 9000, cpuMs: 8000),
                    ShortLivedGroup(path: "/bin/sh", name: "sh", parentPid: 4242, parentName: "", count: 20, sightings: 4, aliveMs: 200, cpuMs: 0),
                ])
            }
            var s = SessionReading(); s.frontPid = 20; s.idleSeconds = 3
            rec.session = s
            try recorder?.append(rec)
            try pipeline.ingest(rec)
            if let share = pipeline.takeUnknownCpuShare() { shares.append(share) }
        }
        return shares
    }

    func testUnattributedCpuIsReportedAndStaysUnattributedWithoutAScan() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let shares = try runChurnScenario(db: db, withScan: false)
        // One core is busy; the readable and foreign processes explain 0.8 s of every 10 s.
        XCTAssertFalse(shares.isEmpty)
        XCTAssertEqual(shares.last ?? 0, 0.92, accuracy: 0.01)
        let unattributed = try appId(db, "system.unattributed")
        XCTAssertGreaterThan(try XCTUnwrap(db.scalarInt("SELECT CAST(share * 100 AS INTEGER) FROM episode_blame WHERE dim = 'cpu' AND app_id = ?", [unattributed])), 85)
    }

    func testScanMovesUnattributedCpuToTheAppThatStartedTheProcesses() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        _ = try runChurnScenario(db: db, withScan: true)
        let builder = try appId(db, "com.example.builder"), unattributed = try appId(db, "system.unattributed")

        // One event per starting app; the group whose starter is unknown has no app.
        try db.query("SELECT value, detail FROM event WHERE kind = 'short_lived' AND app_id = ?", [builder]) { r in
            XCTAssertEqual(r.int(0), 400)
            XCTAssertTrue(r.text(1).contains(#""alive_ms":9000"#)); XCTAssertTrue(r.text(1).contains(#""cpu_ms":8000"#)); XCTAssertTrue(r.text(1).contains(#""name":"clang""#))
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM event WHERE kind = 'short_lived'"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT value FROM event WHERE kind = 'short_lived' AND app_id IS NULL"), 20)

        // The scan saw 0.8 cores' worth of Builder's children; about 0.92 cores were unattributed.
        try db.query("SELECT share, confidence, detail FROM episode_blame WHERE dim = 'cpu' AND app_id = ?", [builder]) { r in
            XCTAssertGreaterThan(r.double(0), 0.7); XCTAssertLessThan(r.double(0), 0.9)
            XCTAssertTrue(r.text(2).contains("short_lived_count"))
        }
        let left = try XCTUnwrap(db.scalarInt("SELECT CAST(share * 100 AS INTEGER) FROM episode_blame WHERE dim = 'cpu' AND app_id = ?", [unattributed]))
        XCTAssertTrue((5...25).contains(left), "what the scan does not explain stays unattributed, got \(left) %")
        let total = try XCTUnwrap(db.scalarInt("SELECT CAST(SUM(share) * 100 + 0.5 AS INTEGER) FROM episode_blame WHERE dim = 'cpu' AND role = 'culprit'"))
        XCTAssertTrue((95...100).contains(total), "shares still add up, got \(total) %")
    }

    func testReplayWithOptionalDataIsIdentical() throws {
        let dir = tempDir(self)
        for (name, run) in [("gpu", { db, rec in _ = try self.runGpuScenario(db: db, recorder: rec) }),
                            ("churn", { db, rec in _ = try self.runChurnScenario(db: db, recorder: rec, withScan: true) })]
            as [(String, (Database, Recorder) throws -> Void)] {
            let live = try Database(path: dir + "/\(name)-live.db")
            let recorder = try Recorder(path: dir + "/\(name).jsonl", host: testHost())
            try run(live, recorder)
            recorder.close()
            let replayed = try Database(path: dir + "/\(name)-replay.db")
            try Replayer.replay(recording: dir + "/\(name).jsonl", into: replayed)
            for (table, order) in [("sys_sample", "sample_id"), ("app_sample", "sample_id, app_id"), ("event", "event_id"),
                                   ("episode_blame", "episode_id, app_id, dim"), ("capture", "capture_id")] {
                XCTAssertEqual(try dump(live, table, orderBy: order), try dump(replayed, table, orderBy: order), "\(name): \(table)")
            }
        }
    }

    func testCaptureRowsExpireWithEpisodeEvidence() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        _ = try runGpuScenario(db: db)
        let now = try XCTUnwrap(db.scalarInt("SELECT MAX(ts) FROM sample"))
        let retention = Retention(db: db, policy: RetentionPolicy())
        _ = try db.transaction { try retention.run(now: now + 29 * 86_400_000, rolledUpTo: now) }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM capture"), 1)
        _ = try db.transaction { try retention.run(now: now + 31 * 86_400_000, rolledUpTo: now) }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM capture"), 0)
    }
}
