import XCTest
@testable import PmonCore

final class RollupTests: XCTestCase {
    typealias Rig = ProcessPipelineTests.Rig

    /// 130 minutes of a small machine: Editor busy and growing, Browser in focus for the first hour.
    func run(db: Database, minutes: Int = 130, retention: RetentionPolicy = RetentionPolicy(), hog: Range<Int>? = nil) throws {
        let pipeline = try Pipeline(db: db, host: testHost(), retention: retention)
        let rig = Rig()
        rig.fake.bundles = [10: ("/Applications/Editor.app", "editor", "Editor"), 20: ("/Applications/Browser.app", "browser", "Browser")]
        let editor = rig.fake.spawn(pid: 10, footprint: 300 << 20), browser = rig.fake.spawn(pid: 20, footprint: 500 << 20)
        for i in 0..<(minutes * 12) {
            let minute = i / 12
            var rec = rig.tick { f in
                if let hog, hog.contains(minute) { f.run(editor, cpuMs: 16_000, waitMs: 30_000) }
                else { f.run(editor, cpuMs: 1000, diskMB: 1) }
                f.run(browser, cpuMs: 100)
                if i % 120 == 0 { f.procs[editor]!.footprint += 10 << 20 }
            }
            var s = SessionReading(); s.frontPid = minute < 60 ? 20 : 10; s.idleSeconds = 5
            rec.session = s
            try pipeline.ingest(rec)
        }
    }

    func appId(_ db: Database, _ key: String) throws -> Int64 { try db.scalarInt("SELECT app_id FROM app WHERE key = ?", [key]) ?? -1 }

    func testMinuteRollupEqualsDirectAggregation() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db)
        let mark = try XCTUnwrap(db.scalarInt("SELECT value FROM state WHERE key = 'rollup_1m'"))
        let last = try XCTUnwrap(db.scalarInt("SELECT MAX(ts) FROM sample"))
        XCTAssertTrue((120_000...240_000).contains(last - mark), "rolled up to two minutes behind the present")

        // Totals over all rolled minutes match the raw rows exactly.
        for (rolled, raw) in [("cpu_ms", "x.cpu_ms"), ("disk_write", "x.d_disk_write"), ("focus_ms", "CASE WHEN x.is_focus = 1 THEN s.proc_dt_ms ELSE 0 END")] {
            XCTAssertEqual(try db.scalarInt("SELECT SUM(\(rolled)) FROM app_rollup_1m"),
                           try db.scalarInt("SELECT SUM(\(raw)) FROM app_sample x JOIN sample s USING (sample_id) WHERE s.ts < ?", [mark]), rolled)
        }
        XCTAssertEqual(try db.scalarInt("SELECT SUM(covered_ms) FROM sys_rollup_1m"),
                       try db.scalarInt("SELECT SUM(dt_ms) FROM sample JOIN sys_sample USING (sample_id) WHERE ts < ?", [mark]))

        // One ordinary minute in detail.
        let bucket = try XCTUnwrap(db.scalarInt("SELECT bucket_ts FROM sys_rollup_1m ORDER BY bucket_ts LIMIT 1 OFFSET 30"))
        try db.query("SELECT covered_ms, cpu_busy_pct_avg, cpu_busy_pct_max, slug_index_max, sluggish_ms, awake_ms, user_present_ms FROM sys_rollup_1m WHERE bucket_ts = ?", [bucket]) { r in
            XCTAssertEqual(r.int(0), 60_000); XCTAssertEqual(r.double(1), 25, accuracy: 0.001); XCTAssertEqual(r.double(2), 25, accuracy: 0.001)
            XCTAssertLessThan(r.int(3), 40); XCTAssertEqual(r.int(4), 0); XCTAssertEqual(r.int(5), 60_000); XCTAssertEqual(r.int(6), 60_000)
        }
        try db.query("SELECT covered_ms, cpu_ms, cpu_fg_ms, cpu_pct_max, footprint_avg, footprint_max, footprint_last, disk_write, focus_ms, proc_max FROM app_rollup_1m WHERE bucket_ts = ? AND app_id = ?",
                     [bucket, try appId(db, "editor")]) { r in
            XCTAssertEqual(r.int(0), 60_000, "six process sweeps of 10 s")
            XCTAssertEqual(r.int(1), 12_000); XCTAssertEqual(r.int(2), 12_000); XCTAssertEqual(r.double(3), 20, accuracy: 0.001)
            XCTAssertEqual(r.int(4), r.int(5)); XCTAssertEqual(r.int(6), r.int(5))
            XCTAssertEqual(r.int(7), 12 << 20); XCTAssertEqual(r.int(8), 0); XCTAssertEqual(r.int(9), 1)
        }
        XCTAssertEqual(try db.scalarInt("SELECT focus_ms FROM app_rollup_1m WHERE bucket_ts = ? AND app_id = ?", [bucket, try appId(db, "browser")]), 60_000)
    }

    func testHourAndDayRollupsAndIdempotence() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db)
        // Two complete hours (the run starts on the hour).
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_rollup_1h"), 2)
        let hour = try XCTUnwrap(db.scalarInt("SELECT MIN(bucket_ts) FROM sys_rollup_1h"))
        XCTAssertEqual(try db.scalarInt("SELECT covered_ms FROM sys_rollup_1h WHERE bucket_ts = ?", [hour + 3_600_000]), 3_600_000)
        for column in ["cpu_ms", "disk_write", "focus_ms", "covered_ms"] {
            XCTAssertEqual(try db.scalarInt("SELECT SUM(\(column)) FROM app_rollup_1h WHERE bucket_ts = ?", [hour + 3_600_000]),
                           try db.scalarInt("SELECT SUM(\(column)) FROM app_rollup_1m WHERE bucket_ts >= ? AND bucket_ts < ?", [hour + 3_600_000, hour + 7_200_000]), column)
        }
        try db.query("SELECT footprint_avg, footprint_max, footprint_last, cpu_pct_max FROM app_rollup_1h WHERE bucket_ts = ? AND app_id = ?", [hour + 3_600_000, try appId(db, "editor")]) { r in
            XCTAssertLessThan(r.int(0), r.int(1), "the editor grew during the hour"); XCTAssertEqual(r.int(2), r.int(1), "and ended at its peak")
            XCTAssertEqual(r.double(3), 20, accuracy: 0.001)
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_rollup_1d"), 0, "no day is complete yet")

        // Rolling again from scratch rewrites the same rows.
        let before = try ["sys_rollup_1m", "app_rollup_1m", "sys_rollup_1h", "app_rollup_1h"].map { try dump(db, $0, orderBy: "1, 2") }
        try db.run("DELETE FROM state")
        try Rollup(db: db).run(now: try XCTUnwrap(db.scalarInt("SELECT MAX(ts) FROM sample")))
        let after = try ["sys_rollup_1m", "app_rollup_1m", "sys_rollup_1h", "app_rollup_1h"].map { try dump(db, $0, orderBy: "1, 2") }
        XCTAssertEqual(before, after)
        XCTAssertEqual(try Rollup(db: db).run(now: try XCTUnwrap(db.scalarInt("SELECT MAX(ts) FROM sample"))), [], "nothing left to do")
    }

    func testEpisodeTimeAndBlameReachTheRollups() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db, minutes: 70, hog: 20..<22)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT SUM(episodes) FROM sys_rollup_1m"), 1)
        let sluggish = try XCTUnwrap(db.scalarInt("SELECT SUM(sluggish_ms) FROM sys_rollup_1m"))
        XCTAssertTrue((90_000...180_000).contains(sluggish), "\(sluggish) ms inside the episode")
        // Blame, in sluggish-minutes caused, lands on the editor in the minute the episode ended, and carries to the hour.
        let blame = try XCTUnwrap(db.scalarInt("SELECT CAST(SUM(blame) * 1000 AS INTEGER) FROM app_rollup_1m WHERE app_id = ?", [try appId(db, "editor")]))
        XCTAssertTrue((1500...3000).contains(blame), "about two minutes of slowdown, nearly all of it the editor's: \(Double(blame) / 1000) min")
        XCTAssertEqual(try db.scalarInt("SELECT CAST(SUM(blame) * 1000 AS INTEGER) FROM app_rollup_1h WHERE app_id = ?", [try appId(db, "editor")]), blame)
        XCTAssertNil(try db.scalarInt("SELECT SUM(blame) FROM app_rollup_1m WHERE app_id = ?", [try appId(db, "browser")]))
    }

    func testRetentionKeepsEpisodeWindowsAndRollups() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        var policy = RetentionPolicy(); policy.rawHours = 0.5
        try run(db: db, minutes: 130, retention: policy, hog: 20..<22)
        let now = try XCTUnwrap(db.scalarInt("SELECT MAX(ts) FROM sample"))
        var ep: (Int64, Int64) = (0, 0)
        try db.query("SELECT start_ts, end_ts FROM episode") { ep = ($0.int(0), $0.int(1)) }

        // Retention ran when each hour completed: everything older than half an hour before the last
        // full hour is gone, except the episode and five minutes either side.
        let cutoff = (now / 3_600_000) * 3_600_000 - 1_800_000
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE ts < ? AND (ts < ? OR ts > ?)", [cutoff, ep.0 - 300_000, ep.1 + 300_000]), 0)
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE ts BETWEEN ? AND ?", [ep.0, ep.1]) ?? 0, 10)
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM proc_sample x JOIN sample s USING (sample_id) WHERE s.ts BETWEEN ? AND ?", [ep.0, ep.1]) ?? 0, 10)
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM app_sample x JOIN sample s USING (sample_id) WHERE s.ts BETWEEN ? AND ?", [ep.0 - 300_000, ep.0]) ?? 0, 0,
                             "the lead-up is preserved too")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM proc_sample WHERE sample_id NOT IN (SELECT sample_id FROM sample)"), 0, "no orphaned rows")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample WHERE sample_id NOT IN (SELECT sample_id FROM sample)"), 0)
        // History survives in the rollups, and recent raw data is untouched.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_rollup_1m WHERE bucket_ts < ?", [cutoff]), (cutoff - (try XCTUnwrap(db.scalarInt("SELECT MIN(bucket_ts) FROM sys_rollup_1m")))) / 60_000)
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE ts >= ?", [now - 600_000]) ?? 0, 100)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM episode_blame"), try db.scalarInt("SELECT COUNT(*) FROM episode_blame b JOIN app a USING (app_id)"))
    }

    func testRetentionWorksInBatchesAndPrunesOldProcesses() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db, minutes: 70)
        let now = try XCTUnwrap(db.scalarInt("SELECT MAX(ts) FROM sample"))
        try db.run("INSERT INTO process (boot_id, pid, start_ts, source, exe_id, app_id, first_seen, last_seen, exited_ts) VALUES (1, 999, 1, 0, 1, 1, 1, 1, 2)")
        var policy = RetentionPolicy(); policy.rawHours = 0.25; policy.batchSamples = 100
        let retention = Retention(db: db, policy: policy)
        let before = try XCTUnwrap(db.scalarInt("SELECT COUNT(*) FROM sample"))
        XCTAssertTrue(try retention.run(now: now, rolledUpTo: now), "more than one batch is waiting")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample"), before - 100)
        var passes = 1
        while try retention.run(now: now, rolledUpTo: now) { passes += 1 }
        XCTAssertGreaterThan(passes, 3)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE ts < ?", [now - 900_000]), 0)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE pid = 999"), 0, "a long-exited process nobody refers to is removed")
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM process WHERE pid = 10"), 1, "a live process stays")
        // Nothing is deleted before it has been rolled up.
        let other = try Database(path: tempDir(self) + "/b.db")
        try run(db: other, minutes: 20)
        let n = try other.scalarInt("SELECT COUNT(*) FROM sample")
        _ = try Retention(db: other, policy: policy).run(now: now + 86_400_000, rolledUpTo: nil)
        XCTAssertEqual(try other.scalarInt("SELECT COUNT(*) FROM sample"), n)
    }
}

final class FindingsTests: XCTestCase {
    let now: Int64 = 1_800_000_000_000 + 48 * 3_600_000
    var db: Database!

    override func setUpWithError() throws {
        db = try Database(path: tempDir(self) + "/f.db")
        try Migrations.migrate(db)
        for (id, key) in [(1, "leaky"), (2, "sawtooth"), (3, "hog"), (4, "focused-hog"), (5, "writer"), (6, "storm"), (7, "odd"), (8, "looper"), (9, "system.machine")] {
            try db.run("INSERT INTO app (app_id, key, name, kind) VALUES (?, ?, ?, 'app')", [id, key, key])
        }
    }

    func hourly(_ app: Int, hoursAgo: Int, footprintMB: Double, cpuPct: Double = 1, writeGB: Double = 0, focusPct: Double = 0) throws {
        try db.run("INSERT OR REPLACE INTO app_rollup_1h (bucket_ts, app_id, covered_ms, cpu_ms, footprint_avg, disk_write, focus_ms) VALUES (?, ?, 3600000, ?, ?, ?, ?)",
                   [now - Int64(hoursAgo) * 3_600_000, app, Int64(cpuPct * 36_000), Int64(footprintMB * 1_048_576), Int64(writeGB * 1_073_741_824), Int64(focusPct * 36_000)])
    }

    func minute(_ app: Int, minutesAgo: Int, cpuPct: Double, wakeupsPerS: Double = 0, focusMs: Int = 0) throws {
        try db.run("INSERT INTO app_rollup_1m (bucket_ts, app_id, covered_ms, cpu_ms, wakeups, focus_ms) VALUES (?, ?, 60000, ?, ?, ?)",
                   [now - Int64(minutesAgo) * 60_000, app, Int64(cpuPct * 600), Int64(wakeupsPerS * 60), focusMs])
    }

    func kinds(_ app: Int) throws -> [String] {
        var k: [String] = []
        try db.query("SELECT kind FROM finding WHERE app_id = ? AND status = 'open' ORDER BY kind", [app]) { k.append($0.text(0)) }
        return k
    }

    func testLeakFiresOnSteadyGrowthNotOnSawtooth() throws {
        for h in 0..<10 {
            try hourly(1, hoursAgo: 10 - h, footprintMB: 400 + Double(h) * 60)                      // +540 MB, linear
            try hourly(2, hoursAgo: 10 - h, footprintMB: 400 + (h % 2 == 0 ? 0 : 500))               // up and down
            try hourly(3, hoursAgo: 10 - h, footprintMB: 400 + Double(h) * 5)                       // steady but small
        }
        try Findings(db: db).run(now: now, machineApp: 9)
        XCTAssertEqual(try kinds(1), ["leak_suspect"]); XCTAssertEqual(try kinds(2), []); XCTAssertEqual(try kinds(3), [])
        let evidence = try XCTUnwrap(db.scalarInt("SELECT json_extract(evidence, '$.growth_mb') FROM finding WHERE app_id = 1"))
        XCTAssertEqual(evidence, 540)
    }

    func testRunawayCpuNeedsTenBackgroundMinutes() throws {
        for m in 1...15 { try minute(3, minutesAgo: m, cpuPct: 95); try minute(4, minutesAgo: m, cpuPct: 95, focusMs: 60_000) }
        for m in 1...8 { try minute(5, minutesAgo: m, cpuPct: 95) }                                  // too short
        for m in 1...15 { try minute(7, minutesAgo: m * 3, cpuPct: 95) }                             // not consecutive
        try Findings(db: db).run(now: now, machineApp: 9)
        XCTAssertEqual(try kinds(3), ["runaway_cpu"])
        XCTAssertEqual(try kinds(4), [], "busy while in focus is the user's own doing")
        XCTAssertEqual(try kinds(5), []); XCTAssertEqual(try kinds(7), [])
        XCTAssertEqual(try db.scalarInt("SELECT json_extract(evidence, '$.minutes') FROM finding WHERE app_id = 3"), 15)
    }

    func testWakeupStormDiskWriterCrashLoopAndFullDisk() throws {
        for m in 1...12 { try minute(6, minutesAgo: m, cpuPct: 2, wakeupsPerS: 2500) }
        for h in 1...20 { try hourly(5, hoursAgo: h, footprintMB: 100, writeGB: 0.4); try hourly(4, hoursAgo: h, footprintMB: 100, writeGB: 0.4, focusPct: 60) }
        try db.run("INSERT INTO boot (boot_id, session_uuid, boot_ts) VALUES (1, 'b', 0)")
        try db.run("INSERT INTO executable (exe_id, path, name) VALUES (1, '/opt/looper', 'looper')")
        // Four crash reports for one app within the hour; one for another; and plenty of short-lived
        // processes, which by themselves mean nothing (a build, or launchd's on-demand workers).
        for i in 0..<4 { try db.run("INSERT INTO event (ts, kind, app_id) VALUES (?, 'crash', 8)", [now - 1_800_000 + Int64(i) * 60_000]) }
        try db.run("INSERT INTO event (ts, kind, app_id) VALUES (?, 'crash', 7)", [now - 600_000])
        try db.run("INSERT INTO event (ts, kind, app_id) VALUES (?, 'crash', 3)", [now - 2 * 86_400_000])
        for i in 0..<14 {
            let start = now - 1_200_000 + Int64(i) * 10_000
            try db.run("INSERT INTO process (boot_id, pid, start_ts, source, exe_id, app_id, first_seen, last_seen, exited_ts) VALUES (1, ?, ?, 0, 1, 6, ?, ?, ?)",
                       [2000 + i, start, start, start, start + 5000])
        }
        try db.run("INSERT INTO sample (sample_id, ts, boot_id, dt_ms, tier) VALUES (1, ?, 1, 5000, 1)", [now])
        try db.run("INSERT INTO volume_sample (sample_id, mount, total, free) VALUES (1, '/', ?, ?)", [Int64(250) << 30, Int64(11) << 30])
        try Findings(db: db).run(now: now, machineApp: 9)
        XCTAssertEqual(try kinds(6), ["wakeup_storm"])
        XCTAssertEqual(try kinds(5), ["disk_writer"]); XCTAssertEqual(try kinds(4), [], "8 GB written, but while in focus")
        XCTAssertEqual(try kinds(8), ["crash_loop"])
        XCTAssertEqual(try db.scalarInt("SELECT json_extract(evidence, '$.crashes_in_hour') FROM finding WHERE kind = 'crash_loop'"), 4)
        XCTAssertEqual(try kinds(7), [], "one crash is not a loop")
        XCTAssertEqual(try kinds(6), ["wakeup_storm"], "many short-lived processes without crash reports are not a crash loop")
        XCTAssertEqual(try kinds(9), ["disk_nearly_full"])
        XCTAssertEqual(try db.scalarInt("SELECT severity FROM finding WHERE kind = 'disk_nearly_full'"), 2, "under 5 % free")
    }

    func testBaselinesAndAnomaly() throws {
        for h in 2...40 { try hourly(7, hoursAgo: h, footprintMB: 300, cpuPct: 3 + Double(h % 4)) }
        try hourly(7, hoursAgo: 1, footprintMB: 300, cpuPct: 45)                                     // the latest hour is far out of line
        for h in 1...40 { try hourly(3, hoursAgo: h, footprintMB: 300, cpuPct: 40) }                  // always busy: normal for it
        let f = Findings(db: db)
        try f.updateBaselines(now: now)
        try db.query("SELECT p50, p95, n FROM app_baseline WHERE app_id = 7 AND metric = 'cpu_pct' AND hour_of_week = 168") { r in
            XCTAssertEqual(r.double(0), 4.5, accuracy: 1); XCTAssertEqual(r.double(1), 6, accuracy: 0.5); XCTAssertEqual(r.int(2), 40)
        }
        XCTAssertGreaterThan(try db.scalarInt("SELECT COUNT(*) FROM app_baseline WHERE app_id = 7 AND hour_of_week < 168") ?? 0, 20)
        try f.run(now: now, machineApp: 9)
        XCTAssertEqual(try kinds(7), ["anomaly"]); XCTAssertEqual(try kinds(3), [])
    }

    func testFindingsAreRefreshedNotDuplicatedAndCloseWhenStale() throws {
        for h in 0..<10 { try hourly(1, hoursAgo: 10 - h, footprintMB: 400 + Double(h) * 60) }
        let f = Findings(db: db)
        try f.run(now: now, machineApp: 9)
        try f.run(now: now + 3_600_000, machineApp: 9)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM finding WHERE app_id = 1"), 1)
        XCTAssertEqual(try db.scalarInt("SELECT last_ts FROM finding WHERE app_id = 1"), now + 3_600_000)
        // Two days later the growth has left the 24-hour window: the finding closes.
        try f.run(now: now + 50 * 3_600_000, machineApp: 9)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM finding WHERE app_id = 1 AND status = 'closed'"), 1)
        // If it comes back, that is a new finding.
        for h in 0..<10 { try hourly(1, hoursAgo: -50 + 10 - h, footprintMB: 400 + Double(h) * 60) }
        try f.run(now: now + 50 * 3_600_000, machineApp: 9)
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM finding WHERE app_id = 1"), 2)
    }
}
