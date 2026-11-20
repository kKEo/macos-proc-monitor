import XCTest
@testable import PmonCore

func fixture(_ name: String) -> String {
    let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)!
    return try! String(contentsOf: url, encoding: .utf8)
}

let soakStats = ["pid", "cpu", "time", "mem", "cmprs", "pageins", "csw", "threads", "idlew", "power", "instrs", "cycles", "faults", "uid", "ppid"]

final class TopParserTests: XCTestCase {
    func testParsesRealSoakOutput() throws {
        var p = TopParser(stats: soakStats)
        p.feed(fixture("soak_two_samples.log"))
        p.flush()
        let samples = try p.take().map { try $0.get() }
        XCTAssertEqual(samples.count, 2)
        for rows in samples {
            XCTAssertGreaterThan(rows.count, 400)
            XCTAssertEqual(Set(rows.map(\.pid)).count, rows.count, "one row per pid")
            let kernel = rows.first { $0.pid == 0 }
            XCTAssertNotNil(kernel, "kernel_task is present")
            XCTAssertGreaterThan(kernel!.threads, 100, "thread column in total/running form is parsed")
            XCTAssertGreaterThan(kernel!.cpuNs, 0)
            XCTAssertTrue(rows.contains { $0.mem > 100 << 20 }, "sizes with M suffix are parsed")
            XCTAssertTrue(rows.allSatisfy { $0.cpuNs < 400 * 3600 * 1_000_000_000 })
        }
        // Cumulative columns never decrease between the two samples for the same pid.
        let first = Dictionary(uniqueKeysWithValues: samples[0].map { ($0.pid, $0) })
        var compared = 0
        for row in samples[1] {
            guard let a = first[row.pid] else { continue }
            compared += 1
            XCTAssertGreaterThanOrEqual(row.cpuNs, a.cpuNs); XCTAssertGreaterThanOrEqual(row.pageins, a.pageins)
        }
        XCTAssertGreaterThan(compared, 400)
    }

    func testFeedingInSmallChunksGivesTheSameResult() throws {
        let text = fixture("soak_two_samples.log")
        var whole = TopParser(stats: soakStats)
        whole.feed(text); whole.flush()
        var chunked = TopParser(stats: soakStats)
        var i = text.startIndex
        while i < text.endIndex {
            let j = text.index(i, offsetBy: 37, limitedBy: text.endIndex) ?? text.endIndex
            chunked.feed(String(text[i..<j])); i = j
        }
        chunked.flush()
        XCTAssertEqual(try whole.take().map { try $0.get() }, try chunked.take().map { try $0.get() })
    }

    func testSampleCompletesOnNextSampleOrOnFlush() throws {
        var p = TopParser(stats: soakStats)
        p.feed(fixture("soak_two_samples.log"))
        XCTAssertEqual(p.take().count, 1, "the second sample is not complete until the stream goes quiet")
        p.flush()
        XCTAssertEqual(p.take().count, 1)
        p.flush()
        XCTAssertEqual(p.take().count, 0, "flushing twice yields nothing new")
    }

    func testFlushWaitsForAnIncompleteLine() {
        var p = TopParser(stats: ["pid", "time", "mem"])
        p.feed("Processes: 2 total\n\nPID TIME MEM\n1 00:01.00 10M\n2 00:0")
        p.flush()
        XCTAssertTrue(p.take().isEmpty, "a half-written row must not be parsed")
        p.feed("2.50 3K\n")
        p.flush()
        let rows = try? p.take().first?.get()
        XCTAssertEqual(rows?.count, 2)
        XCTAssertEqual(rows?[1].cpuNs, 2_500_000_000); XCTAssertEqual(rows?[1].mem, 3 * 1024)
    }

    func testChangedHeaderIsAFailureNotAMisparse() {
        var p = TopParser(stats: ["pid", "time", "mem"])
        p.feed("Processes: 1 total\n\nPID MEM TIME\n1 10M 00:01.00\n")
        p.flush()
        guard case .failure(.headerMismatch)? = p.take().first else { return XCTFail("expected header mismatch") }
    }

    func testBadRowRejectsItsSampleButNotTheNext() {
        var p = TopParser(stats: ["pid", "time", "mem"])
        p.feed("Processes: 2 total\n\nPID TIME MEM\n1 00:01.00 10M\n2 garbage\n")
        p.feed("Processes: 1 total\n\nPID TIME MEM\n1 00:02.00 11M+\n")
        p.flush()
        let results = p.take()
        XCTAssertEqual(results.count, 2)
        guard case .failure(.badRow) = results[0] else { return XCTFail("first sample should be rejected") }
        XCTAssertEqual(try? results[1].get().first?.mem, 11 << 20)
    }

    func testValueFormats() {
        XCTAssertEqual(TopParser.size("0B"), 0)
        XCTAssertEqual(TopParser.size("3953K"), 3953 * 1024)
        XCTAssertEqual(TopParser.size("436M+"), 436 << 20)
        XCTAssertEqual(TopParser.size("1.5G-"), 1536 << 20)
        XCTAssertNil(TopParser.size("N/A"))
        XCTAssertEqual(TopParser.count("1525262+"), 1_525_262)
        XCTAssertNil(TopParser.count("12x"))
        XCTAssertEqual(TopParser.cpuTime("04:37.49")?.ns, 277_490_000_000)
        XCTAssertEqual(TopParser.cpuTime("04:37.49")?.coarse, false)
        XCTAssertEqual(TopParser.cpuTime("10:03:21")?.ns, 36_201_000_000_000, "past an hour top shows whole seconds")
        XCTAssertEqual(TopParser.cpuTime("10:03:21")?.coarse, true)
        XCTAssertNil(TopParser.cpuTime("12")); XCTAssertNil(TopParser.cpuTime("1:75.00"))
    }

    func testOtherFixtureColumnSets() throws {
        var a = TopParser(stats: ["pid", "time", "mem", "idlew", "instrs", "cycles", "pageins"])
        a.feed(fixture("two_samples_10s.log")); a.flush()
        XCTAssertEqual(try a.take().map { try $0.get().count > 300 }, [true, true])
        var b = TopParser(stats: ["pid", "time", "mem", "idlew", "instrs", "cpu"])
        b.feed(fixture("stop_cont_gap.log")); b.flush()
        XCTAssertEqual(try b.take().map { _ = try $0.get(); return 1 }.count, 7)
    }
}

final class PsCollectorTests: XCTestCase {
    func testParse() {
        let rows = PsCollector.parse("  583  50:26.25   7:10.30\n    1   4:41.02  15:52.93\nbroken line\n  410 603:21.32 142:00.51\n")
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0], PsRow(pid: 583, userNs: 3_026_250_000_000, sysNs: 430_300_000_000))
        XCTAssertEqual(rows[2].userNs, (603 * 60 + 21) * 1_000_000_000 + 320_000_000)
        XCTAssertEqual(PsCollector.time("1:02:03.50"), 3_723_500_000_000)
        XCTAssertNil(PsCollector.time("abc"))
    }

    func testReadsRealProcessesIncludingOtherUsers() {
        let sample = PsCollector().collect(pids: [1, getpid(), 99_998])      // launchd is owned by root; the last pid (almost certainly) does not exist
        XCTAssertNotNil(sample)
        XCTAssertEqual(Set(sample!.rows.map(\.pid)), [1, getpid()])
        XCTAssertGreaterThan(sample!.rows.first { $0.pid == 1 }!.userNs + sample!.rows.first { $0.pid == 1 }!.sysNs, 0)
        XCTAssertNil(PsCollector().collect(pids: []))
    }
}

final class TopStreamTests: XCTestCase {
    func waitUntil(_ timeout: Double = 5, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.05) }
        return condition()
    }

    func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    func fakeTop(_ script: String, stats: [String] = soakStats) -> TopStream {
        TopStream(intervalSeconds: 30, stats: stats, command: ["/bin/sh", "-c", script])
    }

    func testDeliversSamplesAndLeavesNoChildBehind() {
        let path = Bundle.module.url(forResource: "Fixtures/soak_two_samples.log", withExtension: nil)!.path
        let s = fakeTop("cat '\(path)'; exec sleep 60")
        s.start()
        var sample: TopSample?
        XCTAssertTrue(waitUntil { sample = sample ?? s.take(); return sample != nil })
        XCTAssertGreaterThan(sample!.rows.count, 400)
        XCTAssertGreaterThan(sample!.monoNs, 0)
        XCTAssertEqual(s.state, .running)
        XCTAssertEqual(s.takeNotes().map(\.value), [1], "announces the top source once")
        XCTAssertNil(s.take(), "a sample is handed out once")
        let pid = s.childPid
        XCTAssertNotNil(pid)
        s.stop()
        XCTAssertEqual(s.state, .stopped)
        XCTAssertTrue(waitUntil { !self.alive(pid!) }, "child is gone after stop")
    }

    func testChangedFormatFailsOverToPs() {
        let s = fakeTop(#"printf 'Processes: 1 total\n\nPID UNEXPECTED COLUMNS\n1 2 3\n'; exec sleep 60"#, stats: ["pid", "time", "mem"])
        s.start()
        XCTAssertTrue(waitUntil { s.needsFallback })
        XCTAssertNil(s.take())
        let notes = s.takeNotes()
        XCTAssertEqual(notes.map(\.value), [2])
        XCTAssertTrue(notes[0].detail?.contains(#""mode":"ps""#) ?? false)
        XCTAssertNil(s.childPid, "the unusable child is killed")
        s.stop()
    }

    func testChildThatKeepsDyingFailsAfterBoundedRestarts() {
        let s = fakeTop("exit 0")
        s.restartBaseSeconds = 0.02; s.maxRestarts = 3
        s.start()
        XCTAssertTrue(waitUntil { s.needsFallback })
        if case .failed(let reason) = s.state { XCTAssertTrue(reason.contains("exited")) } else { XCTFail() }
        s.stop()
    }

    func testChildIsRestartedAfterACrash() {
        let path = Bundle.module.url(forResource: "Fixtures/soak_two_samples.log", withExtension: nil)!.path
        let s = fakeTop("cat '\(path)'; exec sleep 60")
        s.restartBaseSeconds = 0.05
        s.start()
        XCTAssertTrue(waitUntil { s.take() != nil })
        let first = s.childPid!
        kill(first, SIGKILL)
        XCTAssertTrue(waitUntil { s.childPid != nil && s.childPid != first }, "a new child replaces the dead one")
        XCTAssertTrue(waitUntil { s.take() != nil }, "and delivers samples again")
        s.stop()
    }

    func testPauseAndResume() {
        let s = fakeTop("exec sleep 60")
        s.start()
        XCTAssertTrue(waitUntil { s.childPid != nil })
        let pid = s.childPid!
        func psState() -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "state=", "-p", "\(pid)"]
            let out = Pipe(); p.standardOutput = out; try? p.run(); p.waitUntilExit()
            return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        s.pause()
        XCTAssertEqual(s.state, .paused)
        XCTAssertTrue(waitUntil { psState().hasPrefix("T") }, "child is suspended")
        s.resume()
        XCTAssertEqual(s.state, .running)
        XCTAssertTrue(waitUntil { !psState().hasPrefix("T") })
        s.pause()
        s.stop()
        XCTAssertTrue(waitUntil { !self.alive(pid) }, "a suspended child is still cleaned up on stop")
    }

    func testOrphanFromAPreviousRunIsNotLeftSuspended() throws {
        // Only a process named "top" whose parent is launchd is treated as our orphan; anything else is left alone.
        let dir = tempDir(self)
        let pidFile = dir + "/top.pid"
        try "\(getpid())\n".write(toFile: pidFile, atomically: true, encoding: .utf8)
        let s = TopStream(intervalSeconds: 30, stats: ["pid", "time", "mem"], pidFile: pidFile, command: ["/bin/sh", "-c", "exec sleep 60"])
        s.start()
        XCTAssertTrue(alive(getpid()), "an unrelated pid in a stale pid file is never signalled")
        XCTAssertTrue(waitUntil { s.childPid != nil })
        XCTAssertEqual(try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "\(s.childPid!)")
        s.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: pidFile))
    }
}

final class ForeignEngineTests: XCTestCase {
    func row(_ pid: Int32, cpuMs: UInt64, mem: UInt64 = 100 << 20, idlew: UInt64 = 0, instrs: UInt64 = 0) -> TopRow {
        var r = TopRow(); r.pid = pid; r.cpuNs = cpuMs * 1_000_000; r.mem = mem; r.cmprs = 5 << 20; r.idlew = idlew; r.instrs = instrs; r.threads = 3
        return r
    }

    func testTopDeltas() {
        var e = TopDeltaEngine()
        let map: [Int32: UInt64] = [1: 1, 88: 2]
        XCTAssertNil(e.deltas(TopSample(monoNs: 10_000_000_000, rows: [row(1, cpuMs: 5000), row(88, cpuMs: 100), row(500, cpuMs: 9)]), uidByPid: map))
        let r = e.deltas(TopSample(monoNs: 40_000_000_000, rows: [row(1, cpuMs: 8000, mem: 120 << 20, idlew: 40, instrs: 777), row(88, cpuMs: 100)]), uidByPid: map)!
        XCTAssertEqual(r.dtMs, 30_000)
        XCTAssertEqual(r.rows.count, 2, "rows for pids that are not foreign processes are ignored")
        let d = r.rows[1]!
        XCTAssertEqual(d.cpuUserMs, 3000); XCTAssertEqual(d.cpuSysMs, 0); XCTAssertEqual(d.dFootprint, 20 << 20)
        XCTAssertEqual(d.dWakeups, 40); XCTAssertEqual(d.dInstructions, 777, "instructions are already per-interval")
        XCTAssertEqual(d.compressed, 5 << 20); XCTAssertEqual(d.fidelity, 1)
        XCTAssertEqual(r.rows[2]!.cpuNs, 0)
    }

    func testNewForeignProcessIsBaselineAndPidReuseIsSeparate() {
        var e = TopDeltaEngine()
        _ = e.deltas(TopSample(monoNs: 10_000_000_000, rows: [row(1, cpuMs: 5000)]), uidByPid: [1: 1])
        // pid 88 appears; and pid 1 now belongs to a different instance (uid 9) with a smaller counter.
        let r = e.deltas(TopSample(monoNs: 40_000_000_000, rows: [row(1, cpuMs: 20), row(88, cpuMs: 4000)]), uidByPid: [1: 9, 88: 2])!
        XCTAssertTrue(r.rows.isEmpty)
        let r2 = e.deltas(TopSample(monoNs: 70_000_000_000, rows: [row(1, cpuMs: 50), row(88, cpuMs: 4500)]), uidByPid: [1: 9, 88: 2])!
        XCTAssertEqual(r2.rows[9]?.cpuUserMs, 30); XCTAssertEqual(r2.rows[2]?.cpuUserMs, 500)
    }

    func testPsDeltas() {
        var e = PsDeltaEngine()
        let map: [Int32: UInt64] = [1: 1]
        XCTAssertNil(e.deltas(PsSample(monoNs: 1, rows: [PsRow(pid: 1, userNs: 1_000_000_000, sysNs: 2_000_000_000)]), uidByPid: map))
        let d = e.deltas(PsSample(monoNs: 2, rows: [PsRow(pid: 1, userNs: 1_400_000_000, sysNs: 2_100_000_000)]), uidByPid: map)!
        XCTAssertEqual(d[1]?.userMs, 400); XCTAssertEqual(d[1]?.sysMs, 100); XCTAssertEqual(d[1]?.ns, 500_000_000)
        e.reset()
        XCTAssertNil(e.deltas(PsSample(monoNs: 3, rows: [PsRow(pid: 1, userNs: 2_000_000_000, sysNs: 3_000_000_000)]), uidByPid: map))
    }

    func testCumulativeSeriesInterpolates() {
        var s = CumulativeSeries()
        s.anchor(at: 100)
        s.add(50, at: 200); s.add(100, at: 300)
        XCTAssertEqual(s.value(at: 100), 0); XCTAssertEqual(s.value(at: 150), 25); XCTAssertEqual(s.value(at: 200), 50)
        XCTAssertEqual(s.value(at: 250), 100); XCTAssertEqual(s.value(at: 300), 150)
        XCTAssertNil(s.value(at: 99)); XCTAssertNil(s.value(at: 301))
    }
}

final class ForeignPipelineTests: XCTestCase {
    typealias Rig = ProcessPipelineTests.Rig

    /// Foreign pids 1 and 88 (see FakeProcs) with cumulative CPU that advances at fixed rates.
    struct FakeTop {
        var cpuMs: [Int32: UInt64] = [1: 10_000, 88: 500]
        var mem: [Int32: UInt64] = [1: 200 << 20, 88: 40 << 20]
        /// Advance by `seconds`: pid 1 uses 30 % of a core, pid 88 uses 2 %.
        mutating func advance(seconds: UInt64) { cpuMs[1]! += seconds * 300; cpuMs[88]! += seconds * 20; mem[1]! += 1 << 20 }
        func sample(at monoNs: UInt64) -> TopSample {
            TopSample(monoNs: monoNs, rows: [1, 88].map { pid in
                var r = TopRow(); r.pid = Int32(pid); r.cpuNs = cpuMs[Int32(pid)]! * 1_000_000; r.mem = mem[Int32(pid)]!
                r.cmprs = 1 << 20; r.threads = 7; r.idlew = cpuMs[Int32(pid)]! / 10; r.instrs = 1234
                return r
            })
        }
        func ps(at monoNs: UInt64) -> PsSample {
            PsSample(monoNs: monoNs, rows: [1, 88].map { PsRow(pid: Int32($0), userNs: cpuMs[Int32($0)]! * 600_000, sysNs: cpuMs[Int32($0)]! * 400_000) })
        }
    }

    /// 14 ticks (70 s); own process uses 40 % of a core; a top sample is attached every 30 s,
    /// taken `lead` seconds before the tick that picks it up.
    func run(db: Database, lead: Double, ps: Bool = false, recorder: Recorder? = nil) throws {
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        let own = rig.fake.spawn(pid: 10)
        var top = FakeTop()
        for i in 0..<14 {
            var rec = rig.tick { $0.run(own, cpuMs: i == 0 ? 0 : 2000) }
            if i > 0 { top.advance(seconds: 5) }
            if rec.procs != nil {
                if i % 6 == 0 {
                    // The sample was taken `lead` seconds ago: rewind the counters by that much.
                    var past = top
                    past.cpuMs[1]! -= UInt64(lead * 300); past.cpuMs[88]! -= UInt64(lead * 20)
                    rec.top = past.sample(at: rec.tick.monoNs - UInt64(lead * 1e9))
                    if i == 0 { rec.notes = [CollectorNote(kind: "foreign_source", value: 1, detail: #"{"mode":"top"}"#)] }
                }
                if ps { rec.ps = top.ps(at: rec.tick.monoNs) }
            }
            try recorder?.append(rec)
            try pipeline.ingest(rec)
        }
    }

    func testTopRowsResidualsAndFlags() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db, lead: 0)
        // Top samples at t=0 (baseline), 30, 60: two fresh ticks.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 8"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE foreign_dt_ms = 30000"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 32"), 0)
        try db.query("""
            SELECT p.cpu_user_ms, p.cpu_sys_ms, p.footprint, p.mem_compressed, p.d_footprint, p.d_instructions, p.threads, p.fidelity,
                   p.cpu_p_ms, p.cpu_fg_ms, p.runnable_ms, p.rss, p.d_disk_write, p.d_energy_uj, p.reason
            FROM proc_sample p JOIN process pr USING (proc_id) WHERE pr.pid = 1 ORDER BY p.sample_id LIMIT 1
            """) { r in
            XCTAssertEqual(r.int(0), 9000, "30 s at 30 % of a core"); XCTAssertEqual(r.int(1), 0)
            XCTAssertEqual(r.int(2), 206 << 20); XCTAssertEqual(r.int(3), 1 << 20); XCTAssertEqual(r.int(4), 6 << 20)
            XCTAssertEqual(r.int(5), 1234); XCTAssertEqual(r.int(6), 7); XCTAssertEqual(r.int(7), 1)
            for i in 8...13 { XCTAssertTrue(r.isNull(i), "\(r.name(i)) is not available from top and must be NULL") }
            XCTAssertEqual(r.int(14) & 16, 0)
        }
        // System busy 5000 ms per 5 s (FakeMachine) = 30000 per 30 s; own 12000; foreign 9000 + 600.
        try db.query("SELECT foreign_cpu_ms, unknown_cpu_ms, unattributed_cpu_ms FROM sys_sample WHERE foreign_cpu_ms IS NOT NULL") { r in
            XCTAssertEqual(r.int(0), 9600)
            XCTAssertEqual(r.int(1), 30_000 - 12_000 - 9600)
            XCTAssertEqual(r.int(2), 10_000 - 4000, "per process interval: busy minus natively read processes")
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM event WHERE kind = 'foreign_source' AND value = 1"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample WHERE unattributed_disk_bytes IS NOT NULL AND unattributed_disk_bytes >= 0"),
                       try db.scalarInt("SELECT COUNT(*) FROM sample WHERE proc_dt_ms IS NOT NULL"))
    }

    func testTopSampleTakenBetweenTicksIsAlignedByInterpolation() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db, lead: 3)          // each sample is 3 s old when the tick picks it up
        // With steady rates the answer must be the same as in the aligned case.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample WHERE foreign_cpu_ms = 9600"), 2)
        // The first top sample predates the first tick, so system totals do not cover its window:
        // the residual is left unknown rather than guessed. The second window is fully covered.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample WHERE unknown_cpu_ms IS NOT NULL"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT unknown_cpu_ms FROM sys_sample WHERE unknown_cpu_ms IS NOT NULL"), 30_000 - 12_000 - 9600)
    }

    func testPsIsTheOnlyCpuSourceWhileActive() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db, lead: 0, ps: true)
        // ps on every sweep: baseline at t=0, then deltas at 10, 20, ... 60.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 32"), 6)
        // CPU-only rows between top samples.
        try db.query("""
            SELECT p.cpu_user_ms, p.cpu_sys_ms, p.footprint, p.fidelity, p.reason FROM proc_sample p
            JOIN process pr USING (proc_id) JOIN sample s USING (sample_id) WHERE pr.pid = 1 AND s.foreign_dt_ms IS NULL LIMIT 1
            """) { r in
            XCTAssertEqual(r.int(0), 1800); XCTAssertEqual(r.int(1), 1200, "ps splits user and system time")
            XCTAssertTrue(r.isNull(2)); XCTAssertEqual(r.int(3), 2); XCTAssertEqual(r.int(4) & 16, 16)
        }
        // On a top tick the row has top's memory but ps's CPU for the last 10 s, not top's 30 s.
        try db.query("""
            SELECT p.cpu_user_ms + p.cpu_sys_ms, p.footprint, p.fidelity, p.reason FROM proc_sample p
            JOIN process pr USING (proc_id) JOIN sample s USING (sample_id) WHERE pr.pid = 1 AND s.foreign_dt_ms IS NOT NULL LIMIT 1
            """) { r in
            XCTAssertEqual(r.int(0), 3000); XCTAssertNotNil(r.optInt(1)); XCTAssertEqual(r.int(2), 1); XCTAssertEqual(r.int(3) & 16, 16)
        }
        // Total foreign CPU over the run is counted exactly once: 60 s x (30 % + 2 %).
        XCTAssertEqual(try db.scalarInt("SELECT SUM(foreign_cpu_ms) FROM sys_sample"), 60 * 320)
        XCTAssertEqual(try db.scalarInt("SELECT MIN(unknown_cpu_ms) FROM sys_sample WHERE unknown_cpu_ms IS NOT NULL"), 10_000 - 4000 - 3200)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(unknown_cpu_ms) FROM sys_sample"), 10_000 - 4000 - 3200)
    }

    func testReplayWithForeignDataIsIdentical() throws {
        let dir = tempDir(self)
        let live = try Database(path: dir + "/live.db")
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost())
        try run(db: live, lead: 2, ps: true, recorder: recorder)
        recorder.close()
        let replayed = try Database(path: dir + "/replay.db")
        try Replayer.replay(recording: dir + "/run.jsonl", into: replayed)
        for (table, order) in [("sample", "sample_id"), ("sys_sample", "sample_id"), ("proc_sample", "sample_id, proc_id"), ("event", "event_id")] {
            let a = try dump(live, table, orderBy: order), b = try dump(replayed, table, orderBy: order)
            XCTAssertFalse(a.isEmpty, table)
            XCTAssertEqual(a, b, "\(table) differs between live run and replay")
        }
    }
}
