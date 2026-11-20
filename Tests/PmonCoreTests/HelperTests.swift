import XCTest
@testable import PmonCore

/// The helper is exercised unprivileged: the same server code, run in-process as the test user.
/// What only root can do (reading other users' processes) is covered by the pipeline tests below.
final class HelperTests: XCTestCase {
    /// A server on a short socket path (the limit is 104 bytes), stopped when the test ends.
    func serve(_ policy: HelperPolicy) throws -> (HelperServer, String) {
        let path = "/tmp/pmon-h-\(getpid())-\(UInt32.random(in: 0..<UInt32.max)).sock"
        let server = HelperServer(socketPath: path, policy: policy)
        try server.start()
        Thread.detachNewThread { server.run() }
        addTeardownBlock { server.stop() }
        return (server, path)
    }

    /// Send raw bytes, return the first reply line.
    func raw(_ path: String, _ text: String) -> String? {
        var addr = Sock.address(path)!
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return nil }
        Sock.setTimeout(fd, seconds: 5)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = Sock.writeAll(fd, Data(text.utf8))
        var reader = Sock.Reader(fd: fd)
        return reader.line(limit: 1 << 20).map { String(decoding: $0, as: UTF8.self) }
    }

    func testHelloAndRead() throws {
        let (_, path) = try serve(HelperPolicy(allowedUid: getuid()))
        let client = HelperClient(socketPath: path)
        XCTAssertFalse(client.connected)
        XCTAssertTrue(client.connect())
        XCTAssertEqual(client.version, PmonVersion.string); XCTAssertFalse(client.isRoot)

        // Unprivileged, the helper reads what the test user may read: itself, not launchd.
        let procs = try XCTUnwrap(client.read(pids: [getpid(), 1, 99_998]))
        XCTAssertEqual(procs.map(\.pid), [getpid()])
        XCTAssertGreaterThan(procs[0].uid, 0); XCTAssertGreaterThan(procs[0].footprint, 0); XCTAssertGreaterThan(procs[0].cpuNs, 0)
        XCTAssertEqual(client.read(pids: [])?.count, 0, "the connection is reused")
        XCTAssertTrue(client.connected)
    }

    func testMalformedAndOutOfRangeRequestsAreRejected() throws {
        let (_, path) = try serve(HelperPolicy(allowedUid: getuid()))
        func error(_ request: String) -> String? {
            raw(path, request + "\n").flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["error"] as? String }
        }
        XCTAssertEqual(error("not json"), "bad request")
        XCTAssertEqual(error(#"{"pids":[1]}"#), "bad request", "no op")
        XCTAssertEqual(error(#"{"op":"shell","kind":"rm -rf /"}"#), "unknown op")
        XCTAssertEqual(error(#"{"op":"read"}"#), "bad pid list")
        XCTAssertEqual(error(#"{"op":"read","pids":[-1]}"#), "bad pid list")
        XCTAssertEqual(error(#"{"op":"read","pids":["1"]}"#), "bad request")
        XCTAssertEqual(error(#"{"op":"read","pids":[\#((0...HelperLimits.maxPids).map(String.init).joined(separator: ","))]}"#), "bad pid list", "too many")
        XCTAssertEqual(error(#"{"op":"capture","kind":"/bin/sh"}"#), "unknown capture")
        XCTAssertEqual(error(#"{"op":"capture","kind":"sample"}"#), "bad pid", "a pid is required")
        XCTAssertEqual(error(#"{"op":"capture","kind":"footprint","pid":0}"#), "bad pid")
        // An endless line is cut off rather than buffered.
        XCTAssertNil(raw(path, String(repeating: "x", count: HelperLimits.maxLine + 70_000)))
        // And the server is still serving.
        XCTAssertTrue(HelperClient(socketPath: path).connect())
    }

    func testCaptureCommandsAreAFixedListThatTakesOnlyAPid() {
        XCTAssertEqual(Set(HelperCapture.allCases.map(\.rawValue)), ["sample", "footprint", "spindump", "powermetrics"])
        for kind in HelperCapture.allCases {
            let cmd = kind.command(pid: 4242)
            XCTAssertTrue(cmd.tool.hasPrefix("/usr/bin/") || cmd.tool.hasPrefix("/usr/sbin/"), cmd.tool)
            XCTAssertEqual(cmd.args.contains("4242"), kind.needsPid)
        }
    }

    func testOtherUsersAreRefused() throws {
        let (_, path) = try serve(HelperPolicy(allowedUid: getuid() + 1))
        XCTAssertFalse(HelperClient(socketPath: path).connect(), "not even a greeting")
        XCTAssertTrue(raw(path, #"{"op":"read","pids":[1]}"# + "\n")?.contains("not allowed") ?? false)
    }

    func testOnlyTheExpectedExecutableMayReadOrCapture() throws {
        // Any process of the user may ask for the version; counters need the right client.
        let (_, wrong) = try serve(HelperPolicy(allowedUid: getuid(), clientPath: "/usr/bin/true"))
        let stranger = HelperClient(socketPath: wrong)
        XCTAssertTrue(stranger.connect())
        XCTAssertNil(stranger.read(pids: [getpid()]))
        XCTAssertFalse(stranger.connected, "a refused client is dropped")
        XCTAssertNil(stranger.capture(.footprint, pid: getpid()))

        // The test runner itself, identified by its audit token and code signature.
        let me = try XCTUnwrap(Bundle.main.executablePath)
        let (_, right) = try serve(HelperPolicy(allowedUid: getuid(), clientPath: me))
        let friend = HelperClient(socketPath: right)
        XCTAssertTrue(friend.connect())
        XCTAssertEqual(friend.read(pids: [getpid()])?.count, 1)

        // A signing requirement the runner cannot satisfy.
        let (_, strict) = try serve(HelperPolicy(allowedUid: getuid(), requirement: #"identifier "dev.pmon.nobody""#))
        let unsigned = HelperClient(socketPath: strict)
        XCTAssertTrue(unsigned.connect())
        XCTAssertNil(unsigned.read(pids: [getpid()]))
    }

    func testCaptureThroughTheHelper() throws {
        let (_, path) = try serve(HelperPolicy(allowedUid: getuid()))
        let client = HelperClient(socketPath: path)
        XCTAssertTrue(client.connect())
        let data = try XCTUnwrap(client.capture(.footprint, pid: getpid()))
        XCTAssertEqual(Array(data.prefix(2)), [0x1f, 0x8b], "gzip")
        XCTAssertNil(client.capture(.footprint, pid: 99_998), "a failed tool is an error, not empty output")
        XCTAssertEqual(client.read(pids: [getpid()])?.count, 1, "captures use their own connection")

        // The capture manager stores what the helper returns for a process it could not examine itself.
        var config = CollectorConfig(); config.footprint = .always
        let manager = CaptureManager(dir: tempDir(self) + "/captures", config: config, helper: client)
        let t = CaptureTarget(pid: getpid(), name: "xctest", cpuShare: 0.5, footprint: 1 << 20, foreign: true)
        manager.submit(CaptureRequest(episodeId: 3, ts: 1000, dominant: "memory", cpuTop: [t], memTop: [t]), onBattery: false, batteryPct: nil)
        var got: [CaptureResult] = []
        let deadline = Date().addingTimeInterval(20)
        while got.isEmpty, Date() < deadline { got += manager.take(); usleep(100_000) }
        XCTAssertEqual(got.map(\.kind), ["footprint"])
        XCTAssertTrue(got[0].summary.hasPrefix("xctest: "), got[0].summary); XCTAssertGreaterThan(got[0].summary.count, 12)
        XCTAssertTrue(FileManager.default.fileExists(atPath: got[0].path))

        // Without a helper, a foreign target is skipped.
        let alone = CaptureManager(dir: tempDir(self) + "/captures", config: config)
        alone.submit(CaptureRequest(episodeId: 4, ts: 2000, dominant: "memory", cpuTop: [t], memTop: [t]), onBattery: false, batteryPct: nil)
        usleep(800_000)
        XCTAssertTrue(alone.take().isEmpty)
    }

    func testCollectorsFallBackTheMomentTheHelperStops() throws {
        let (server, path) = try serve(HelperPolicy(allowedUid: getuid()))
        let client = HelperClient(socketPath: path)
        XCTAssertTrue(client.connect())
        let collectors = LiveCollectors(helper: client)
        collectors.helperMinCoverage = 0          // this helper is not root and reads no system process
        let clock = SystemClock()
        var planner = TickPlanner(systemSeconds: 0.5, processSeconds: 0.5, slowSeconds: 0.5)

        let first = collectors.collect(for: planner.plan(clock: clock, deadlineNs: nil))
        XCTAssertTrue(collectors.helperActive)
        XCTAssertNotNil(first.procs?.helper); XCTAssertNil(first.ps, "no ps while the helper answers")
        XCTAssertTrue(first.notes?.contains { $0.kind == "foreign_source" && $0.value == 3 } ?? false)

        // With the normal rule, a helper that cannot read system processes is not relied on.
        let cautious = LiveCollectors(helper: client)
        var other = TickPlanner(systemSeconds: 0.5, processSeconds: 0.5, slowSeconds: 0.5)
        let rec = cautious.collect(for: other.plan(clock: clock, deadlineNs: nil))
        XCTAssertFalse(cautious.helperActive); XCTAssertNil(rec.procs?.helper); XCTAssertNotNil(rec.ps)

        server.stop()
        usleep(600_000)                 // the next tick is due
        let second = collectors.collect(for: planner.plan(clock: clock, deadlineNs: nil))
        XCTAssertFalse(collectors.helperActive)
        XCTAssertNil(second.procs?.helper)
        XCTAssertGreaterThan(second.ps?.rows.count ?? 0, 10, "the same sweep is covered by ps instead")
        XCTAssertTrue(second.notes?.contains { $0.kind == "foreign_source" && $0.value == 1 } ?? false)
        usleep(600_000)
        XCTAssertNotNil(collectors.collect(for: planner.plan(clock: clock, deadlineNs: nil)).ps, "ps carries on until top delivers")
    }
}

final class HelperPipelineTests: XCTestCase {
    typealias Rig = ProcessPipelineTests.Rig

    /// Ten sweeps with the helper reading both system processes (pids 1 and 88), then the helper
    /// disappears and the top stream takes over.
    func run(db: Database, recorder: Recorder? = nil) throws {
        let pipeline = try Pipeline(db: db, host: testHost())
        let rig = Rig()
        let app = rig.fake.spawn(pid: 10)
        var system: [ProcReading] = rig.fake.foreign.map { var r = ProcReading(); r.pid = $0.pid; r.uid = $0.uid; r.footprint = 30 << 20; r.threads = 2; return r }
        var topMs: UInt64 = 50_000
        for i in 0..<40 {
            var rec = rig.tick { $0.run(app, cpuMs: 500) }
            if rec.procs != nil {
                if i < 20 {
                    system[0].userNs += 1_500_000_000; system[0].fgNs += 1_500_000_000; system[0].diskWrite += 3 << 20   // launchd: 1.5 s CPU, 3 MB
                    system[1].sysNs += 400_000_000; system[1].bgNs += 400_000_000; system[1].energyNj += 9_000_000
                    rec.procs?.helper = system
                } else {
                    topMs += 700
                    var a = TopRow(); a.pid = 1; a.cpuNs = topMs * 1_000_000; a.mem = 30 << 20; a.threads = 2
                    var b = TopRow(); b.pid = 88; b.cpuNs = 9_000_000_000; b.mem = 30 << 20; b.threads = 2
                    rec.top = TopSample(monoNs: rec.tick.monoNs, rows: [a, b])
                }
            }
            try recorder?.append(rec)
            try pipeline.ingest(rec)
        }
    }

    func testHelperReadingsAreNativeAndTheTopStreamTakesOverCleanly() throws {
        let db = try Database(path: tempDir(self) + "/a.db")
        try run(db: db)
        let launchd = try XCTUnwrap(db.scalarInt("SELECT proc_id FROM process WHERE pid = 1"))
        XCTAssertEqual(try db.scalarInt("SELECT source FROM process WHERE pid = 1"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT source FROM process WHERE pid = 88"), 2)
        XCTAssertEqual(try db.scalarInt("SELECT source FROM process WHERE pid = 10"), 0)

        // With the helper: exact rows at the process interval, with the metrics only native reads give.
        try db.query("""
            SELECT COUNT(*), MIN(x.cpu_user_ms), MAX(x.cpu_user_ms), MIN(x.d_disk_write), MIN(x.cpu_fg_ms), MAX(s.proc_dt_ms)
            FROM proc_sample x JOIN sample s USING (sample_id) WHERE x.proc_id = ? AND x.fidelity = 0
            """, [launchd]) { r in
            XCTAssertEqual(r.int(0), 9, "ten helper sweeps: one baseline, nine intervals")
            XCTAssertEqual(r.int(1), 1500); XCTAssertEqual(r.int(2), 1500)
            XCTAssertEqual(r.int(3), 3 << 20); XCTAssertEqual(r.int(4), 1500); XCTAssertEqual(r.int(5), 10_000)
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample WHERE flags & 4"), 9, "the first sweep is only a baseline")
        // Every process is read, so the remainder is known exactly on each of those ticks:
        // 10 s of busy CPU minus 1.0 s (app), 1.5 s and 0.4 s.
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sys_sample WHERE foreign_cpu_ms = 1900 AND unknown_cpu_ms = 7100"), 9)
        // Disk: the device wrote 4 MB per 10 s, of which launchd is now known to account for 3 MB.
        let residual = try XCTUnwrap(db.scalarInt("""
            SELECT MAX(x.d_disk_write) FROM app_sample x JOIN sample s USING (sample_id) JOIN app a USING (app_id)
            WHERE a.key = 'system.foreign' AND s.flags & 4
            """))
        XCTAssertEqual(residual, 1 << 20)

        // After the helper is gone: top-stream rows, and no delta that spans the helper period.
        try db.query("""
            SELECT COUNT(*), MIN(x.cpu_user_ms), MAX(x.cpu_user_ms), COUNT(x.d_disk_write)
            FROM proc_sample x JOIN sample s USING (sample_id) WHERE x.proc_id = ? AND x.fidelity = 1
            """, [launchd]) { r in
            XCTAssertEqual(r.int(0), 9, "ten top samples: one baseline, nine intervals")
            XCTAssertEqual(r.int(1), 700); XCTAssertEqual(r.int(2), 700)
            XCTAssertEqual(r.int(3), 0, "the top stream cannot supply disk activity: NULL, not 0")
        }
        XCTAssertEqual(try db.scalarInt("SELECT COUNT(*) FROM sample s WHERE flags & 4 AND s.sample_id > (SELECT MIN(sample_id) FROM proc_sample WHERE fidelity = 1)"), 0)
    }

    func testReplayWithHelperDataIsIdentical() throws {
        let dir = tempDir(self)
        let live = try Database(path: dir + "/live.db")
        let recorder = try Recorder(path: dir + "/run.jsonl", host: testHost())
        try run(db: live, recorder: recorder)
        recorder.close()
        let replayed = try Database(path: dir + "/replay.db")
        try Replayer.replay(recording: dir + "/run.jsonl", into: replayed)
        for (table, order) in [("sample", "sample_id"), ("sys_sample", "sample_id"), ("proc_sample", "sample_id, proc_id"), ("app_sample", "sample_id, app_id"), ("process", "proc_id")] {
            XCTAssertEqual(try dump(live, table, orderBy: order), try dump(replayed, table, orderBy: order), table)
        }
    }
}
