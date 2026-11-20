import XCTest
@testable import PmonCore

final class ScorerTests: XCTestCase {
    func quiet() -> ScoreInput {
        var x = ScoreInput()
        x.pBusyShare = 0.1; x.waitShare = 0.01; x.canaryMs = 0.2; x.pressureLevel = 1; x.memLevelPct = 50
        x.thrash = 90; x.queueDepth = 0.05; x.diskFreePct = 40
        return x
    }

    func testQuietMachineScoresZero() {
        var s = Scorer()
        for _ in 0..<5 { XCTAssertEqual(s.score(quiet()).index, 0) }
    }

    func testCpuFromWaitBusyAndCanary() {
        var s = Scorer()
        var x = quiet(); x.waitShare = 1.0                      // 16 threads on 8 cores
        XCTAssertEqual(s.score(x).cpu, 100)
        x.waitShare = 0.4
        XCTAssertEqual(s.score(x).cpu, 50)
        x = quiet(); x.pBusyShare = 1.0
        XCTAssertEqual(s.score(x).cpu, 50, "busy performance cores with nothing waiting is capped below the episode threshold")
        x = quiet(); x.canaryMs = 80
        XCTAssertEqual(s.score(x).cpu, 50)
        x = quiet(); x.waitShare = nil
        XCTAssertEqual(s.score(x).cpu, 0, "no process sweep yet: no claim")
    }

    func testMemoryUsesLevelAvailabilityAndSustainedPaging() {
        var s = Scorer()
        var x = quiet(); x.pressureLevel = 2
        XCTAssertEqual(s.score(x).mem, 25, "the sticky 'warn' level alone stays well below an episode")
        x.pressureLevel = 4
        XCTAssertEqual(s.score(x).mem, 75)
        x = quiet(); x.memLevelPct = 8
        XCTAssertEqual(s.score(x).mem, 60)

        // One burst of paging is ignored; a sustained one counts.
        s = Scorer()
        _ = s.score(quiet()); _ = s.score(quiet())
        x = quiet(); x.thrash = 30_000
        XCTAssertEqual(s.score(x).mem, 0, "a single spike is not pressure")
        XCTAssertEqual(s.score(x).mem, 100, "two of the last three samples are high")
        XCTAssertEqual(s.score(quiet()).mem, 100)
        XCTAssertEqual(s.score(quiet()).mem, 0)
    }

    func testDiskQueueIsSustainedAndFullVolumeIsCapped() {
        var s = Scorer()
        var x = quiet(); x.queueDepth = 7.6                      // seen as a one-off on the idle machine
        _ = s.score(quiet()); _ = s.score(quiet())
        XCTAssertEqual(s.score(x).disk, 0)
        XCTAssertEqual(s.score(x).disk, 100)
        s = Scorer()
        x = quiet(); x.diskFreePct = 1
        XCTAssertEqual(s.score(x).disk, 30, "a full volume is a standing condition, not an episode")
        x.diskFreePct = 6
        XCTAssertEqual(s.score(x).disk, 15)
    }

    func testThermalUiAndIndexIsTheMaximum() {
        var s = Scorer()
        var x = quiet(); x.thermalLevel = 2
        XCTAssertEqual(s.score(x).thermal, 70)
        x.hangAgeSeconds = 5; x.hangIsFocus = true
        XCTAssertEqual(s.score(x).ui, 100)
        x.hangIsFocus = false
        XCTAssertEqual(s.score(x).ui, 50)
        x.hangAgeSeconds = 45
        let scores = s.score(x)
        XCTAssertEqual(scores.ui, 0, "a hang report stops counting after 30 s")
        XCTAssertEqual(scores.index, 70, "the index is the worst dimension, not an average")
        XCTAssertNil(scores.gpu)
    }

    func testThresholdOverridesFromPartialJson() throws {
        let t = try JSONDecoder().decode(Thresholds.self, from: Data(#"{"openAt": 70, "thrashHigh": 50000, "thermalScores": [0, 10, 50, 90], "unknown": 1}"#.utf8))
        XCTAssertEqual(t.openAt, 70); XCTAssertEqual(t.thrashHigh, 50_000); XCTAssertEqual(t.thermalScores, [0, 10, 50, 90])
        XCTAssertEqual(t.closeAt, Thresholds().closeAt, "fields not given keep their defaults")
        XCTAssertEqual(try JSONDecoder().decode(Thresholds.self, from: JSONEncoder().encode(Thresholds())), Thresholds())
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"thresholds": {"calmSeconds": 20}, "relaxWhenIdle": false}"#.utf8))
        XCTAssertEqual(c.thresholds.calmSeconds, 20); XCTAssertFalse(c.relaxWhenIdle)
    }
}

final class EpisodeDetectorTests: XCTestCase {
    /// Feed (seconds, index) pairs; return the transitions with their sample time.
    func run(_ series: [(Int64, Int)]) -> [(at: Int64, EpisodeDetector.Transition)] {
        var d = EpisodeDetector()
        return series.compactMap { s in d.observe(ts: s.0 * 1000, index: s.1).map { (s.0, $0) } }
    }

    func testOpensOnThreeOfFiveAndClosesAfterSustainedCalm() {
        var series: [(Int64, Int)] = [(0, 10), (5, 80), (10, 20), (15, 70), (20, 65)]
        series += stride(from: 25, through: 60, by: 5).map { (Int64($0), 90) }
        series += stride(from: 65, through: 130, by: 5).map { (Int64($0), 10) }
        let t = run(series)
        XCTAssertEqual(t.count, 2)
        XCTAssertEqual(t[0].at, 20); XCTAssertEqual(t[0].1, .opened(startTs: 5000), "starts at the first hot sample of the opening window")
        XCTAssertEqual(t[1].1, .closed(endTs: 60_000), "ends at the last active sample, not at the end of the calm period")
        XCTAssertEqual(t[1].at, 105, "45 s of calm after the last active sample")
    }

    func testShortBurstDoesNotOpen() {
        XCTAssertTrue(run([(0, 5), (5, 95), (10, 95), (15, 5), (20, 5), (25, 5), (30, 5)]).isEmpty)
    }

    func testFlappingIsOneEpisode() {
        var series: [(Int64, Int)] = []
        for cycle in 0..<5 {                                   // 10 s hot, 10 s quiet, five times
            let base = Int64(cycle * 20)
            series += [(base, 90), (base + 2, 90), (base + 4, 90), (base + 6, 90), (base + 8, 90), (base + 10, 5), (base + 14, 5), (base + 18, 5)]
        }
        series += stride(from: 100, through: 170, by: 5).map { (Int64($0), 5) }
        let t = run(series)
        XCTAssertEqual(t.count, 2, "one open and one close")
        XCTAssertEqual(t[1].1, .closed(endTs: 88_000))
    }

    func testIndexBetweenThresholdsKeepsAnEpisodeOpenButDoesNotOpenOne() {
        XCTAssertTrue(run((0..<20).map { (Int64($0 * 5), 50) }).isEmpty)
        var series: [(Int64, Int)] = [(0, 90), (5, 90), (10, 90)]
        series += (3..<30).map { (Int64($0 * 5), 45) }
        XCTAssertEqual(run(series).count, 1, "still at or above the close threshold: stays open")
    }

    func testFastCadenceAndForceClose() {
        var d = EpisodeDetector()
        XCTAssertFalse(d.wantsFastCadence)
        _ = d.observe(ts: 0, index: 45)
        XCTAssertTrue(d.wantsFastCadence, "something may be forming")
        _ = d.observe(ts: 5000, index: 10)
        XCTAssertFalse(d.wantsFastCadence)
        for i in 2..<5 { _ = d.observe(ts: Int64(i) * 5000, index: 90) }
        XCTAssertTrue(d.isOpen)
        XCTAssertEqual(d.forceClose(), 20_000)
        XCTAssertFalse(d.isOpen); XCTAssertNil(d.forceClose())
    }

    func testCadencePolicyFastOverridesEverything() {
        let p = CadencePolicy(config: Config())
        var s = SessionReading(); s.displayOn = false
        XCTAssertEqual(p.decide(session: s, fast: true).name, "fast")
        XCTAssertEqual(p.decide(session: s, fast: true).processSeconds, 2)
        var c = Config(); c.relaxWhenIdle = false
        XCTAssertEqual(CadencePolicy(config: c).decide(session: s).name, "normal")
    }
}

final class EpisodePipelineTests: XCTestCase {
    typealias Rig = ProcessPipelineTests.Rig

    func appId(_ db: Database, _ key: String) throws -> Int64? { try db.scalarInt("SELECT app_id FROM app WHERE key = ?", [key]) }

    /// Hog (pid 10) saturates the CPU for a minute; Victim (pid 20) mostly waits; Idle (pid 30) does nothing.
    func runCpuScenario(db: Database, recorder: Recorder? = nil) throws {
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        rig.fake.bundles = [10: ("/Applications/Hog.app", "com.example.hog", "Hog"), 20: ("/Applications/Victim.app", "com.example.victim", "Victim"),
                            30: ("/Applications/Idle.app", "com.example.idle", "Idle")]
        let hog = rig.fake.spawn(pid: 10), victim = rig.fake.spawn(pid: 20), _ = rig.fake.spawn(pid: 30)
        for i in 0..<50 {                                        // 250 s
            let hot = (8..<20).contains(i)                       // 40 s ... 100 s
            var rec = rig.tick { f in
                if hot { f.run(hog, cpuMs: 16_000, waitMs: 14_000); f.run(victim, cpuMs: 300, waitMs: 9000) }
                else { f.run(hog, cpuMs: 50); f.run(victim, cpuMs: 50) }
            }
            var s = SessionReading(); s.frontPid = 20; s.idleSeconds = 3
            rec.session = s
            try recorder?.append(rec)
            try pipeline.ingest(rec)
        }
    }

    func testCpuEpisodeIsDetectedSummarisedAndBlamed() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try runCpuScenario(db: db)

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode"), 1)
        try db.query("""
            SELECT start_ts, end_ts, peak_index, mean_index, dominant, m_cpu, m_mem, user_present, focus_app_id, after_wake
            FROM episode
            """) { r in
            let length = Double(r.int(1) - r.int(0)) / 1000
            XCTAssertTrue((45...70).contains(length), "about a minute, got \(length) s")
            XCTAssertEqual(r.int(2), 100); XCTAssertGreaterThan(r.int(3), 80)
            XCTAssertEqual(r.text(4), "cpu"); XCTAssertGreaterThan(r.int(5), 80); XCTAssertEqual(r.int(6), 0)
            XCTAssertEqual(r.int(7), 1); XCTAssertEqual(r.optInt(8), try? self.appId(db, "com.example.victim")); XCTAssertEqual(r.int(9), 0)
        }
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 16") ?? 0, 5, "samples inside the episode are flagged")

        // The hog carries nearly all of the blame; the app that mostly waited is a victim, not a culprit.
        try db.query("""
            SELECT b.share, b.score, b.role, b.confidence, b.detail, (SELECT pid FROM process WHERE proc_id = b.top_proc_id)
            FROM episode_blame b WHERE b.app_id = ? AND b.dim = 'cpu'
            """, [try appId(db, "com.example.hog")]) { r in
            XCTAssertGreaterThan(r.double(0), 0.9); XCTAssertGreaterThan(r.double(1), 0.7)
            XCTAssertEqual(r.text(2), "culprit"); XCTAssertEqual(r.int(3), 2)
            XCTAssertTrue(r.text(4).contains("cpu_pct")); XCTAssertEqual(r.int(5), 10)
        }
        try db.query("SELECT b.role, b.score, b.share FROM episode_blame b WHERE b.app_id = ?", [try appId(db, "com.example.victim")]) { r in
            XCTAssertEqual(r.text(0), "victim"); XCTAssertEqual(r.double(1), 0, "victims carry no blame"); XCTAssertGreaterThan(r.double(2), 0.3)
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode_blame WHERE app_id = ?", [try appId(db, "com.example.idle")]), 0)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode_blame WHERE dim != 'cpu'"), 0, "dimensions that were quiet are not blamed")
    }

    func testMemoryEpisodeSeparatesHolderGrowerAndVictim() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        rig.fake.bundles = [10: ("/Applications/Holder.app", "holder", "Holder"), 20: ("/Applications/Grower.app", "grower", "Grower"),
                            30: ("/Applications/Editor.app", "editor", "Editor")]
        let holder = rig.fake.spawn(pid: 10, footprint: 3000 << 20), grower = rig.fake.spawn(pid: 20, footprint: 200 << 20)
        let editor = rig.fake.spawn(pid: 30, footprint: 150 << 20)
        _ = holder
        for i in 0..<56 {
            let pressure = (20..<34).contains(i)                 // 100 s ... 170 s
            if i == 20 { rig.machine.reading.pressureLevel = 4; rig.machine.reading.memLevelPct = 9 }
            if i == 34 { rig.machine.reading.pressureLevel = 1; rig.machine.reading.memLevelPct = 50 }
            try pipeline.ingest(rig.tick { f in
                if (6..<20).contains(i) { f.run(grower, cpuMs: 100, growMB: 100) }       // grows 1.4 GB in the lead-up
                if pressure { f.procs[editor]!.pageins += 4000; f.run(editor, cpuMs: 100) }
            })
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE dominant = 'memory'"), 1)
        func row(_ key: String) throws -> (share: Double, role: String, detail: String) {
            var out = (0.0, "", "")
            try db.query("SELECT share, role, detail FROM episode_blame WHERE dim = 'memory' AND app_id = ?", [try appId(db, key)]) { out = ($0.double(0), $0.text(1), $0.text(2)) }
            return out
        }
        let h = try row("holder"), g = try row("grower"), e = try row("editor")
        XCTAssertEqual(h.role, "culprit"); XCTAssertEqual(g.role, "culprit")
        // Holder: 3000 of 4750 MB held, no growth. Grower: 1600 MB held and all of the growth.
        XCTAssertEqual(h.share, 0.6 * 3000 / 4750, accuracy: 0.02)
        XCTAssertEqual(g.share, 0.6 * 1600 / 4750 + 0.4, accuracy: 0.02)
        XCTAssertTrue(g.detail.contains(#""growth_mb":1400"#), g.detail)
        XCTAssertEqual(e.role, "victim", "the editor only paged in what others pushed out")
        XCTAssertGreaterThan(e.share, 0.9)
    }

    func testQuietRunAndShortBurstProduceNoEpisode() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        let a = rig.fake.spawn(pid: 10)
        for i in 0..<40 {
            try pipeline.ingest(rig.tick { f in
                if i == 20 { f.run(a, cpuMs: 16_000, waitMs: 30_000) } else { f.run(a, cpuMs: 200) }
            })
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode"), 0)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(slug_index) FROM sys_sample"), 100, "the burst is visible in the index, just not an episode")
        XCTAssertFalse(pipeline.wantsFastCadence)
    }

    func testSleepClosesAnEpisodeAndRestartClosesADanglingOne() throws {
        let path = tempDir(self) + "/a.db"
        let db = try Database(path: path)
        do {
            let pipeline = try Pipeline(db: db, host: testHost())
            let rig = Rig()
            let a = rig.fake.spawn(pid: 10)
            for _ in 0..<12 { try pipeline.ingest(rig.tick { $0.run(a, cpuMs: 16_000, waitMs: 30_000) }) }
            XCTAssertTrue(pipeline.wantsFastCadence)
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE end_ts IS NULL"), 1)
            rig.clock.sleep(seconds: 3600)
            try pipeline.ingest(rig.tick())
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE end_ts IS NOT NULL"), 1, "sleep ends the episode")
            XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM episode_blame") ?? 0, 0)
            for _ in 0..<12 { try pipeline.ingest(rig.tick { $0.run(a, cpuMs: 16_000, waitMs: 30_000) }) }
            XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE end_ts IS NULL"), 1)
            XCTAssertEqual(try db.scalarInt("SELECT after_wake FROM episode ORDER BY episode_id DESC LIMIT 1"), nil, "summary is written at close")
        }
        _ = try Pipeline(db: Database(path: path), host: testHost())
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode WHERE end_ts IS NULL"), 0, "an episode left open by a stopped daemon is closed")
    }

    func testReplayWithEpisodesIsIdentical() throws {
        let dir = tempDir(self)
        let live = try Database(path: dir + "/live.db")
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost())
        try runCpuScenario(db: live, recorder: recorder)
        recorder.close()
        let replayed = try Database(path: dir + "/replay.db")
        try Replayer.replay(recording: dir + "/run.jsonl", into: replayed)
        for (table, order) in [("sys_sample", "sample_id"), ("sample", "sample_id"), ("episode", "episode_id"), ("episode_blame", "episode_id, app_id, dim")] {
            let x = try dump(live, table, orderBy: order), y = try dump(replayed, table, orderBy: order)
            XCTAssertFalse(x.isEmpty, table)
            XCTAssertEqual(x, y, "\(table) differs between live run and replay")
        }
        // Stricter thresholds on the same recording: no episode at all.
        var strict = Thresholds(); strict.waitShareHigh = 50
        let other = try Database(path: dir + "/strict.db")
        try Replayer.replay(recording: dir + "/run.jsonl", into: other, thresholds: strict)
        XCTAssertEqual(try other.scalarInt("SELECT COUNT(*) FROM episode"), 0)
    }
}
