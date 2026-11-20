import XCTest
@testable import PmonCore

/// A synthetic process table whose counters advance by known amounts.
struct FakeProcs {
    var procs: [UInt64: ProcReading] = [:]
    var foreign: [ProcRef] = [ProcRef(pid: 1, uid: 1), ProcRef(pid: 88, uid: 2)]
    private var announced = Set<UInt64>()
    private var nextUid: UInt64 = 100
    /// Optional app structure: bundle facts and responsible pids, keyed by pid.
    var bundles: [Int32: (path: String, id: String, name: String)] = [:]
    var responsible: [Int32: Int32] = [:]
    var parents: [Int32: Int32] = [:]

    @discardableResult
    mutating func spawn(pid: Int32, startNs: UInt64 = 0, footprint: UInt64 = 50 << 20) -> UInt64 {
        var r = ProcReading()
        r.pid = pid; r.uid = nextUid; r.startNs = startNs; r.footprint = footprint; r.rss = footprint; r.threads = 4
        procs[r.uid] = r
        nextUid += 1
        return r.uid
    }

    mutating func kill(_ uid: UInt64) { procs[uid] = nil }

    /// Burn CPU: `cpuMs` of foreground time, with `waitMs` spent waiting for a core.
    mutating func run(_ uid: UInt64, cpuMs: UInt64, waitMs: UInt64 = 0, growMB: Int64 = 0, diskMB: UInt64 = 0) {
        guard var r = procs[uid] else { return }
        r.userNs += cpuMs * 750_000; r.sysNs += cpuMs * 250_000
        r.fgNs += cpuMs * 1_000_000; r.pNs += cpuMs * 500_000
        r.runnableNs += (cpuMs + waitMs) * 1_000_000       // the kernel counter includes time on a core
        r.footprint = UInt64(Int64(r.footprint) + growMB << 20)
        r.diskWrite += diskMB << 20
        r.energyNj += cpuMs * 3_000_000; r.idleWakeups += 5; r.instructions += cpuMs * 3_000_000; r.csw &+= 10
        procs[uid] = r
    }

    /// Build the sweep a collector would report, including identities of unannounced instances.
    mutating func sweep(durationMs: Double = 5) -> ProcSweep {
        var s = ProcSweep()
        s.procs = procs.values.sorted { $0.uid < $1.uid }
        s.foreign = foreign
        s.durationNs = UInt64(durationMs * 1e6)
        for r in s.procs where announced.insert(r.uid).inserted {
            var id = ProcIdentity()
            id.pid = r.pid; id.uid = r.uid; id.own = true; id.userId = 501; id.ppid = 1; id.parentUid = 1
            id.startTsMs = 1_799_000_000_000 + Int64(r.uid) * 1000
            id.path = "/Applications/Fake\(r.pid).app/Contents/MacOS/fake\(r.pid)"; id.name = "fake\(r.pid)"
            if let b = bundles[r.pid] {
                id.bundlePath = b.path; id.bundleId = b.id; id.bundleName = b.name
                id.path = b.path + "/Contents/MacOS/" + id.name
            } else {
                id.path = "/opt/tools/fake\(r.pid)"
            }
            id.responsiblePid = responsible[r.pid] ?? r.pid
            if let parentPid = parents[r.pid], let parent = procs.values.first(where: { $0.pid == parentPid }) {
                id.ppid = parentPid; id.parentUid = parent.uid
            }
            s.identities.append(id)
        }
        for f in foreign where announced.insert(f.uid).inserted {
            var id = ProcIdentity()
            id.pid = f.pid; id.uid = f.uid; id.own = false; id.startTsMs = 1_799_000_000_000 + Int64(f.uid)
            id.path = f.pid == 1 ? "/sbin/launchd" : "/usr/libexec/foreignd"; id.name = f.pid == 1 ? "launchd" : "foreignd"
            s.identities.append(id)
        }
        return s
    }
}

final class ProcDeltaEngineTests: XCTestCase {
    func testFirstSweepIsBaselineOnly() {
        var engine = ProcDeltaEngine(), fake = FakeProcs()
        let a = fake.spawn(pid: 10)
        fake.run(a, cpuMs: 9999)
        let r = engine.deltas(fake.sweep().procs, monoNs: 10_000_000_000)
        XCTAssertTrue(r.deltas.isEmpty, "lifetime counters of pre-existing processes are not an interval")
        XCTAssertTrue(r.exited.isEmpty)
    }

    func testDeltasAndWaitTime() {
        var engine = ProcDeltaEngine(), fake = FakeProcs()
        let a = fake.spawn(pid: 10)
        _ = engine.deltas(fake.sweep().procs, monoNs: 10_000_000_000)
        fake.run(a, cpuMs: 4000, waitMs: 1500, growMB: 20, diskMB: 3)
        let d = engine.deltas(fake.sweep().procs, monoNs: 20_000_000_000).deltas
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].cpuMs, 4000); XCTAssertEqual(d[0].cpuUserMs, 3000); XCTAssertEqual(d[0].cpuSysMs, 1000)
        XCTAssertEqual(d[0].cpuFgMs, 4000); XCTAssertEqual(d[0].cpuPMs, 2000)
        XCTAssertEqual(d[0].waitMs, 1500, "wait = runnable time minus CPU time")
        XCTAssertEqual(d[0].dFootprint, 20 << 20); XCTAssertEqual(d[0].footprint, 70 << 20)
        XCTAssertEqual(d[0].dDiskWrite, 3 << 20); XCTAssertEqual(d[0].dWakeups, 5); XCTAssertEqual(d[0].dCsw, 10)
        XCTAssertEqual(d[0].dEnergyUj, 12_000_000); XCTAssertFalse(d[0].born)
    }

    func testProcessBornInIntervalContributesItsWholeLife() {
        var engine = ProcDeltaEngine(), fake = FakeProcs()
        fake.spawn(pid: 10)
        _ = engine.deltas(fake.sweep().procs, monoNs: 10_000_000_000)
        let b = fake.spawn(pid: 11, startNs: 14_000_000_000, footprint: 30 << 20)
        fake.run(b, cpuMs: 800)
        let d = engine.deltas(fake.sweep().procs, monoNs: 20_000_000_000).deltas.first { $0.pid == 11 }
        XCTAssertEqual(d?.cpuMs, 800); XCTAssertEqual(d?.born, true)
        XCTAssertEqual(d?.dFootprint, 30 << 20)
    }

    func testExitIsReportedAndPidReuseIsHarmless() {
        var engine = ProcDeltaEngine(), fake = FakeProcs()
        let a = fake.spawn(pid: 10)
        fake.run(a, cpuMs: 50_000)
        _ = engine.deltas(fake.sweep().procs, monoNs: 10_000_000_000)
        fake.kill(a)
        // The same pid is reused by a new, younger process with small counters.
        let b = fake.spawn(pid: 10, startNs: 15_000_000_000)
        fake.run(b, cpuMs: 120)
        let r = engine.deltas(fake.sweep().procs, monoNs: 20_000_000_000)
        XCTAssertEqual(r.exited, [a])
        XCTAssertEqual(r.deltas.count, 1)
        XCTAssertEqual(r.deltas[0].cpuMs, 120, "no negative or huge delta from the old process's counters")
        XCTAssertGreaterThanOrEqual(r.deltas[0].dFootprint, 0)
    }

    func testBackwardsCounterBecomesBaseline() {
        var engine = ProcDeltaEngine(), fake = FakeProcs()
        let a = fake.spawn(pid: 10)
        fake.run(a, cpuMs: 5000)
        _ = engine.deltas(fake.sweep().procs, monoNs: 10_000_000_000)
        fake.procs[a]!.userNs = 1; fake.procs[a]!.sysNs = 1
        XCTAssertTrue(engine.deltas(fake.sweep().procs, monoNs: 20_000_000_000).deltas.isEmpty)
        fake.run(a, cpuMs: 300)
        XCTAssertEqual(engine.deltas(fake.sweep().procs, monoNs: 30_000_000_000).deltas.first?.cpuMs, 300)
    }

    func testContextSwitchCounterWraps() {
        var engine = ProcDeltaEngine(), fake = FakeProcs()
        let a = fake.spawn(pid: 10)
        fake.procs[a]!.csw = UInt32.max - 3
        _ = engine.deltas(fake.sweep().procs, monoNs: 10_000_000_000)
        fake.run(a, cpuMs: 10)
        XCTAssertEqual(engine.deltas(fake.sweep().procs, monoNs: 20_000_000_000).deltas[0].dCsw, 10)
    }
}

final class SelfLimiterTests: XCTestCase {
    func testSlowSweepsRaiseTheLevelAndRecoveryLowersIt() {
        var l = SelfLimiter()
        XCTAssertFalse(l.observe(sweepMs: 80, selfCpuMs: 5, dtMs: 10_000))
        XCTAssertFalse(l.observe(sweepMs: 80, selfCpuMs: 5, dtMs: 10_000))
        XCTAssertTrue(l.observe(sweepMs: 80, selfCpuMs: 5, dtMs: 10_000), "three slow sweeps in a row raise the level")
        XCTAssertEqual(l.level, 1); XCTAssertEqual(l.intervalMultiplier, 2)
        for _ in 0..<29 { XCTAssertFalse(l.observe(sweepMs: 5, selfCpuMs: 5, dtMs: 20_000)) }
        XCTAssertTrue(l.observe(sweepMs: 5, selfCpuMs: 5, dtMs: 20_000), "a sustained quiet period lowers it")
        XCTAssertEqual(l.level, 0)
    }

    func testOneSlowSweepIsIgnored() {
        var l = SelfLimiter()
        for i in 0..<20 { XCTAssertFalse(l.observe(sweepMs: i == 7 ? 500 : 5, selfCpuMs: 5, dtMs: 10_000)) }
        XCTAssertEqual(l.level, 0)
    }

    func testSustainedCpuShareRaisesTheLevel() {
        var l = SelfLimiter()
        var raised = false
        // 300 ms of CPU per 10 s sweep = 3 % of a core, with fast sweeps.
        for _ in 0..<12 where l.observe(sweepMs: 5, selfCpuMs: 300, dtMs: 10_000) { raised = true }
        XCTAssertTrue(raised)
        XCTAssertEqual(l.level, 1)
    }

    func testLevelIsCapped() {
        var l = SelfLimiter()
        for _ in 0..<100 { _ = l.observe(sweepMs: 500, selfCpuMs: 5, dtMs: 10_000) }
        XCTAssertEqual(l.level, SelfLimiter.maxLevel)
    }
}

final class ProcessPipelineTests: XCTestCase {
    /// Drive a pipeline with system ticks every 5 s and process sweeps every 10 s.
    final class Rig {
        let clock = FakeClock(monotonicNs: 100_000_000_000)     // well after boot, so tests can refer to earlier moments
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        var machine = FakeMachine()
        var fake = FakeProcs()
        var records: [TickRecord] = []
        var sweepMs = 5.0
        let selfPid: Int32 = 77

        /// One tick. `work` runs before the tick and describes what happened in the preceding 5 s.
        func tick(_ work: (inout FakeProcs) -> Void = { _ in }) -> TickRecord {
            work(&fake)
            var rec = TickRecord(tick: planner.plan(clock: clock, deadlineNs: nil), system: machine.reading)
            if rec.tick.tiers.contains(.process) { rec.procs = fake.sweep(durationMs: sweepMs); rec.selfPid = selfPid }
            records.append(rec)
            clock.advance(seconds: 5); machine.step()
            return rec
        }
    }

    func testProcessRowsSelectionAndTotals() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        let busy = rig.fake.spawn(pid: 10), idle = rig.fake.spawn(pid: 11), me = rig.fake.spawn(pid: 77, footprint: 9 << 20)
        _ = idle
        try pipeline.ingest(rig.tick())                                   // t=0: baselines
        try pipeline.ingest(rig.tick { $0.run(busy, cpuMs: 2000) })         // t=5: system only
        try pipeline.ingest(rig.tick { $0.run(busy, cpuMs: 2000, waitMs: 700); $0.run(me, cpuMs: 3) })   // t=10: sweep

        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process"), 5, "3 readable + 2 foreign")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE source = 1"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM executable"), 5)

        try db.query("""
            SELECT s.proc_dt_ms, s.tier, y.proc_count, y.thread_count, y.runnable_wait_ms, y.unattributed_cpu_ms
            FROM sample s JOIN sys_sample y USING (sample_id) ORDER BY s.sample_id DESC LIMIT 1
            """) { r in
            XCTAssertEqual(r.int(0), 10_000, "process rows cover two system intervals")
            XCTAssertEqual(r.int(1), 2)
            XCTAssertEqual(r.int(2), 5); XCTAssertEqual(r.int(3), 12)
            XCTAssertEqual(r.int(4), 700)
            // System busy over 10 s is 2 x 5000 ms (FakeMachine); the readable processes used 4003 ms.
            XCTAssertEqual(r.int(5), 10_000 - 4003)
        }
        XCTAssertEqual(try db.scalarInt("SELECT proc_dt_ms FROM sample WHERE tier = 1"), nil, "system-only ticks carry no process interval")

        // The busy process is stored with exact values; the idle one is counted but still listed
        // as a top-memory process; the daemon's own row is always kept.
        try db.query("""
            SELECT p.cpu_user_ms + p.cpu_sys_ms, p.cpu_fg_ms, p.cpu_util_ms, p.runnable_ms, p.footprint, p.reason, p.fidelity
            FROM proc_sample p JOIN process pr USING (proc_id) WHERE pr.pid = 10
            """) { r in
            XCTAssertEqual(r.int(0), 4000); XCTAssertEqual(r.int(1), 4000); XCTAssertEqual(r.int(2), 0)
            XCTAssertEqual(r.int(3), 700); XCTAssertEqual(r.int(4), 50 << 20)
            XCTAssertEqual(r.int(5) & 5, 5, "top CPU and above the floor"); XCTAssertEqual(r.int(6), 0)
        }
        XCTAssertEqual(try db.scalarInt("SELECT p.reason & 8 FROM proc_sample p JOIN process pr USING (proc_id) WHERE pr.pid = 77"), 8)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM proc_sample p JOIN process pr USING (proc_id) WHERE pr.source = 1"), 0,
                       "foreign processes have no counters yet")
    }

    func testIdleProcessesBelowTheFloorAreNotStored() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        var uids: [UInt64] = []
        for pid in 10..<40 { uids.append(rig.fake.spawn(pid: Int32(pid), footprint: UInt64(pid) << 20)) }
        try pipeline.ingest(rig.tick())
        try pipeline.ingest(rig.tick())
        try pipeline.ingest(rig.tick { f in for u in uids { f.run(u, cpuMs: 2) } })
        // 30 nearly idle processes: only the top 5 by CPU and top 5 by footprint are kept.
        let stored = try db.scalarInt("SELECT COUNT(*) FROM proc_sample") ?? 0
        XCTAssertGreaterThanOrEqual(stored, 5); XCTAssertLessThanOrEqual(stored, 10)
        XCTAssertEqual(try db.scalarInt("SELECT proc_count FROM sys_sample ORDER BY sample_id DESC LIMIT 1"), 32)
    }

    func testExitAndRestartReconciliation() throws {
        let path = tempDir(self) + "/a.db"
        let rig = Rig()
        let a = rig.fake.spawn(pid: 10), b = rig.fake.spawn(pid: 11)
        do {
            let pipeline = try Pipeline(db: Database(path: path), host: testHost())
            try pipeline.ingest(rig.tick())
            try pipeline.ingest(rig.tick())
            try pipeline.ingest(rig.tick { $0.kill(a) })
        }
        let db = try Database(path: path, readOnly: true)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE exited_ts IS NOT NULL"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT pid FROM process WHERE exited_ts IS NOT NULL"), 10)

        // The daemon restarts; meanwhile process 11 went away. Its open row must be closed.
        let rig2 = Rig()
        rig2.fake.spawn(pid: 12)
        let pipeline2 = try Pipeline(db: Database(path: path), host: testHost())
        try pipeline2.ingest(rig2.tick())
        _ = b
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE pid = 11 AND exited_ts IS NOT NULL"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE exited_ts IS NULL"), 3, "new process plus the two foreign ones")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE pid = 1"), 1, "a still-running process keeps a single row")
    }

    func testSlowCollectorTriggersBackoffEvent() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        rig.fake.spawn(pid: 10)
        rig.sweepMs = 120                                   // every sweep blows the 50 ms budget
        for _ in 0..<9 { try pipeline.ingest(rig.tick()) }   // sweeps at t=0,10,20,30,40
        XCTAssertEqual(pipeline.backoffLevel, 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM event WHERE kind = 'collector_backoff'"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT value FROM event WHERE kind = 'collector_backoff'"), 1)
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 2") ?? 0, 0, "later samples are flagged degraded")
    }

    func testSleepResetsProcessBaselines() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        let a = rig.fake.spawn(pid: 10)
        try pipeline.ingest(rig.tick())
        try pipeline.ingest(rig.tick { $0.run(a, cpuMs: 1000) })
        rig.clock.sleep(seconds: 7200)
        try pipeline.ingest(rig.tick { $0.run(a, cpuMs: 1000) })          // wake marker; sweep is a new baseline
        try pipeline.ingest(rig.tick { $0.run(a, cpuMs: 1000) })
        try pipeline.ingest(rig.tick { $0.run(a, cpuMs: 1500) })          // first real sweep after the wake
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 1"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM proc_sample"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT cpu_user_ms + cpu_sys_ms FROM proc_sample"), 2500, "only CPU used after the wake baseline")
        XCTAssertEqual(try db.scalarInt("SELECT MAX(proc_dt_ms) FROM sample"), 10_000)
    }

    func testReplayWithProcessesIsIdentical() throws {
        let dir = tempDir(self)
        let live = try Database(path: dir + "/live.db")
        let pipeline = try Pipeline(db: live, host: testHost())
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost())
        let rig = Rig()
        let a = rig.fake.spawn(pid: 10), b = rig.fake.spawn(pid: 11)
        for i in 0..<30 {
            let rec = rig.tick { f in
                f.run(a, cpuMs: UInt64(500 + i * 30), waitMs: UInt64(i * 10), growMB: 1)
                if i == 12 { f.kill(b) }
                if i == 18 { f.spawn(pid: 11, startNs: rig.clock.monotonicNs - 1_000_000_000) }
            }
            try recorder.append(rec); try pipeline.ingest(rec)
        }
        recorder.close()
        let replayed = try Database(path: dir + "/replay.db")
        try Replayer.replay(recording: dir + "/run.jsonl", into: replayed)
        for (table, order) in [("sample", "sample_id"), ("sys_sample", "sample_id"), ("proc_sample", "sample_id, proc_id"),
                               ("process", "proc_id"), ("executable", "exe_id"), ("event", "event_id")] {
            let x = try dump(live, table, orderBy: order), y = try dump(replayed, table, orderBy: order)
            if table != "event" { XCTAssertFalse(x.isEmpty, table) }
            XCTAssertEqual(x, y, "\(table) differs between live run and replay")
        }
        XCTAssertEqual(try live.scalarInt("SELECT COUNT(*) FROM process WHERE pid = 11"), 2, "the reused pid is two process instances")
    }
}

/// Checks against the real machine.
final class NativeProcessCollectorTests: XCTestCase {
    func testSweepSeesThisProcessAndIsFast() {
        let c = NativeProcessCollector()
        let first = c.collect()
        let me = first.procs.first { $0.pid == getpid() }
        XCTAssertNotNil(me)
        XCTAssertGreaterThan(me!.cpuNs, 0); XCTAssertGreaterThan(me!.footprint, 1 << 20); XCTAssertGreaterThan(me!.threads, 0)
        // Runnable time includes time on a core. The two counters are updated at slightly different
        // moments for a running thread, so allow 1 % slack (the delta engine clamps the difference at 0).
        XCTAssertGreaterThanOrEqual(Double(me!.runnableNs), Double(me!.cpuNs) * 0.99)
        XCTAssertGreaterThan(first.procs.count, 20)
        XCTAssertEqual(first.identities.count, first.procs.count + first.foreign.count, "every instance is described on first sight")
        XCTAssertEqual(Set(first.procs.map(\.uid)).count, first.procs.count, "unique ids are unique")

        let ident = first.identities.first { $0.pid == getpid() }
        XCTAssertEqual(ident?.own, true)
        XCTAssertTrue(ident?.path.hasPrefix("/") ?? false)
        XCTAssertGreaterThan(ident?.startTsMs ?? 0, 1_600_000_000_000)
        XCTAssertNotNil(ident?.coalitionId)
        if let foreign = first.identities.first(where: { !$0.own && $0.pid == 1 }) {
            XCTAssertEqual(foreign.path, "/sbin/launchd", "identity is readable for processes of other users")
        }

        let second = c.collect()
        XCTAssertLessThan(second.identities.count, 30, "known instances are not described again")
        XCTAssertLessThan(Double(second.durationNs) / 1e6, 50, "sweep budget")
    }

    func testMeasuredCpuMatchesKnownLoad() {
        let c = NativeProcessCollector()
        var engine = ProcDeltaEngine()
        _ = engine.deltas(c.collect().procs, monoNs: MachTime.ns(mach_absolute_time()))
        // Burn one thread for one second.
        let end = Date().addingTimeInterval(1)
        var x: UInt64 = 1
        while Date() < end { for _ in 0..<100_000 { x = x &* 6364136223846793005 &+ 1 } }
        XCTAssertNotEqual(x, 0)
        let d = engine.deltas(c.collect().procs, monoNs: MachTime.ns(mach_absolute_time())).deltas.first { $0.pid == getpid() }
        XCTAssertNotNil(d)
        XCTAssertTrue((900...1300).contains(d!.cpuMs), "one busy second measured as \(d!.cpuMs) ms")
        XCTAssertEqual(d!.cpuFgMs + d!.cpuUtilMs + d!.cpuBgMs, d!.cpuMs, accuracy: 30, "QoS groups add up to total CPU")
    }
}
