import XCTest
@testable import PmonCore

final class PipelineTests: XCTestCase {
    /// Records as a live run would produce them: one tick every 5 s, slow tier every 60 s.
    func makeRecords(count: Int, sleepBeforeTick: Int? = nil) -> [TickRecord] {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        var machine = FakeMachine()
        var out: [TickRecord] = []
        for i in 0..<count {
            if i == sleepBeforeTick { clock.sleep(seconds: 1800) }
            var rec = TickRecord(tick: planner.plan(clock: clock, deadlineNs: nil), system: machine.reading)
            if rec.tick.tiers.contains(.slow) {
                var slow = SlowReading()
                slow.volumes = [VolumeReading(mount: "/", total: 250 << 30, free: UInt64(12 - i / 12) << 30)]
                slow.batteryPct = 80; slow.onBattery = true; slow.thermalLevel = 1
                rec.slow = slow
            }
            out.append(rec)
            clock.advance(seconds: 5)
            machine.step()
        }
        return out
    }

    func testSamplesAreWrittenWithCorrectValues() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        for r in makeRecords(count: 13) { try pipeline.ingest(r) }

        // The first tick is a baseline, so 12 of 13 ticks produce samples.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample"), 12)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample"), 12)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM boot"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM host"), 1)

        try db.query("""
            SELECT s.dt_ms, s.tier, s.flags, y.p_busy_ms, y.e_busy_ms, y.cpu_idle_ms, y.d_swapouts, y.disk_io_time_ms,
                   y.mem_free, y.mem_compressed, y.compressor_size, y.on_battery, y.battery_pct, y.thermal_level, y.slug_index
            FROM sample s JOIN sys_sample y USING (sample_id) ORDER BY s.sample_id LIMIT 1
            """) { r in
            XCTAssertEqual(r.int(0), 5000); XCTAssertEqual(r.int(2), 0)
            XCTAssertEqual(r.int(3), 4000); XCTAssertEqual(r.int(4), 1000)
            XCTAssertEqual(r.int(5), 20_000 - 5000)
            XCTAssertEqual(r.int(6), 7); XCTAssertEqual(r.int(7), 250)
            XCTAssertEqual(r.int(8), 10_000 * 16384); XCTAssertEqual(r.int(9), 60_000 * 16384); XCTAssertEqual(r.int(10), 20_000 * 16384)
            XCTAssertEqual(r.int(11), 1); XCTAssertEqual(r.int(12), 80); XCTAssertEqual(r.int(13), 1)
            XCTAssertTrue(r.isNull(14), "scores are not computed yet and must be NULL, not 0")
        }
        // No process sweeps in these records, so every sample is system-only.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE tier = 2"), 0)
        // Slow tier fired at tick 0 (baseline, not stored) and tick 12.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM volume_sample"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT free FROM volume_sample"), 11 << 30)
    }

    func testIntervalSpanningSleepIsFlaggedAndDiscarded() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        let pipeline = try Pipeline(db: db, host: testHost())
        for r in makeRecords(count: 8, sleepBeforeTick: 4) { try pipeline.ingest(r) }

        // Ticks: 0 baseline, 1-3 samples, 4 wake marker (no measurements), 5-7 samples.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample"), 7)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 1"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample"), 6)
        XCTAssertEqual(try db.scalarInt("""
            SELECT COUNT(*) FROM sample s LEFT JOIN sys_sample y USING (sample_id) WHERE s.flags & 1 AND y.sample_id IS NULL
            """), 1, "the wake marker carries no measurements")
        // The first sample after the wake covers a normal 5 s interval, not the sleep.
        XCTAssertEqual(try db.scalarInt("SELECT MAX(p_busy_ms) FROM sys_sample"), 4000)
        XCTAssertEqual(try db.scalarInt("SELECT MAX(dt_ms) FROM sample WHERE flags = 0"), 5000)
    }

    func testRestartOnSameBootReusesBootRow() throws {
        let path = tempDir(self) + "/a.db"
        for _ in 0..<2 {
            let pipeline = try Pipeline(db: Database(path: path), host: testHost())
            for r in makeRecords(count: 3) { try pipeline.ingest(r) }
        }
        let db = try Database(path: path, readOnly: true)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM boot"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample"), 4)
        var other = testHost(); other.bootSessionUUID = "TEST-BOOT-2"
        _ = try Pipeline(db: Database(path: path), host: other)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM boot"), 2)
    }

    func testRecordThenReplayProducesIdenticalRows() throws {
        let dir = tempDir(self)
        let records = makeRecords(count: 40, sleepBeforeTick: 17)

        let live = try Database(path: dir + "/live.db")
        let pipeline = try Pipeline(db: live, host: testHost())
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost())
        for r in records { try recorder.append(r); try pipeline.ingest(r) }
        recorder.close()

        let replayed = try Database(path: dir + "/replay.db")
        XCTAssertEqual(try Replayer.replay(recording: dir + "/run.jsonl", into: replayed), 40)

        for (table, order) in [("sample", "sample_id"), ("sys_sample", "sample_id"), ("volume_sample", "sample_id, mount"),
                               ("boot", "boot_id"), ("host", "host_id")] {
            let a = try dump(live, table, orderBy: order), b = try dump(replayed, table, orderBy: order)
            XCTAssertFalse(a.isEmpty, table)
            XCTAssertEqual(a, b, "\(table) differs between live run and replay")
        }
    }

    func testRecorderStopsAtItsSizeCap() throws {
        let dir = tempDir(self)
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost(), capMB: 0)
        for r in makeRecords(count: 5) { try recorder.append(r) }
        recorder.close()
        XCTAssertTrue(recorder.capReached)
        let lines = try String(contentsOfFile: dir + "/run.jsonl", encoding: .utf8).split(separator: "\n").count
        XCTAssertEqual(lines, 2, "header plus the one record that crossed the cap")
    }

    func testConfigDefaultsAndPartialFile() throws {
        let dir = tempDir(self)
        XCTAssertEqual(try Config.load(path: dir + "/missing.json"), Config())
        try #"{"systemIntervalSeconds": 2}"#.write(toFile: dir + "/c.json", atomically: true, encoding: .utf8)
        let c = try Config.load(path: dir + "/c.json")
        XCTAssertEqual(c.systemIntervalSeconds, 2); XCTAssertEqual(c.slowIntervalSeconds, 60)
        try "{ not json".write(toFile: dir + "/bad.json", atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Config.load(path: dir + "/bad.json"))
    }
}
