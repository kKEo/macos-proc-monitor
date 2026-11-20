import XCTest
@testable import PmonCore

/// Recordings of known loads on a real machine (see Support/record_scenarios.sh), replayed
/// through the pipeline. They are the ground truth the thresholds were tuned against: a change
/// to scoring, episode detection or blame that breaks one of these needs a good reason.
///
/// Every load was started from a terminal, so the application expected to take the blame is
/// the terminal app, with `pmon-stress` as its most active process.
final class ScenarioTests: XCTestCase {
    struct Outcome {
        var episodes: [(dominant: String, seconds: Double, peak: Int, means: [String: Int])] = []
        var maxIndex = 0
        /// Per episode: (app that owns pmon-stress, its share in the dominant dimension, role, top process name, rank among culprits).
        var stress: [(share: Double, role: String, topProcess: String, rank: Int, confidence: Int)] = []
        var blamedDimensions: Set<String> = []
    }

    func replay(_ name: String) throws -> Outcome {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/scenarios/\(name).jsonl.gz", withExtension: nil))
        let db = try Database(path: tempDir(self) + "/\(name).db")
        try Replayer.replay(recording: url.path, into: db)
        var out = Outcome()
        out.maxIndex = Int(try db.scalarInt("SELECT MAX(slug_index) FROM sys_sample") ?? 0)
        var ids: [(Int64, String)] = []
        try db.query("SELECT episode_id, dominant, end_ts - start_ts, peak_index, m_cpu, m_mem, m_disk FROM episode ORDER BY start_ts") { r in
            ids.append((r.int(0), r.text(1)))
            out.episodes.append((r.text(1), Double(r.int(2)) / 1000, Int(r.int(3)), ["cpu": Int(r.int(4)), "memory": Int(r.int(5)), "disk": Int(r.int(6))]))
        }
        let stressApp = try db.scalarInt("SELECT p.app_id FROM process p JOIN executable e USING (exe_id) WHERE e.name = 'pmon-stress' LIMIT 1")
        for (id, dominant) in ids {
            var rank = 0, found = false
            try db.query("""
                SELECT b.app_id, b.share, b.role, b.confidence,
                       (SELECT e.name FROM process p JOIN executable e USING (exe_id) WHERE p.proc_id = b.top_proc_id)
                FROM episode_blame b WHERE b.episode_id = ? AND b.dim = ? ORDER BY b.score DESC, b.share DESC
                """, [id, dominant]) { r in
                rank += 1
                if r.optInt(0) == stressApp, !found {
                    found = true
                    out.stress.append((r.double(1), r.text(2), r.optText(4) ?? "", rank, Int(r.int(3))))
                }
            }
            try db.query("SELECT DISTINCT dim FROM episode_blame WHERE episode_id = ?", [id]) { out.blamedDimensions.insert($0.text(0)) }
        }
        return out
    }

    func testQuietMachineHasNoEpisode() throws {
        let o = try replay("quiet")
        XCTAssertTrue(o.episodes.isEmpty)
        XCTAssertLessThan(o.maxIndex, 40, "an idle machine never even approaches the close threshold")
    }

    func testFiveSecondBurstIsVisibleButNotAnEpisode() throws {
        let o = try replay("burst")
        XCTAssertTrue(o.episodes.isEmpty, "16 threads for 5 s is a blip, not a slowdown")
        XCTAssertGreaterThanOrEqual(o.maxIndex, 50, "but it does show in the index")
    }

    func testCpuSaturation() throws {
        let o = try replay("cpu")                        // 16 busy threads on 8 cores for 60 s
        XCTAssertEqual(o.episodes.count, 1)
        XCTAssertEqual(o.episodes[0].dominant, "cpu")
        XCTAssertTrue((40...75).contains(o.episodes[0].seconds), "\(o.episodes[0].seconds) s")
        XCTAssertEqual(o.episodes[0].peak, 100)
        XCTAssertEqual(o.stress.count, 1)
        XCTAssertEqual(o.stress[0].rank, 1); XCTAssertEqual(o.stress[0].role, "culprit")
        XCTAssertGreaterThan(o.stress[0].share, 0.85)
        XCTAssertEqual(o.stress[0].topProcess, "pmon-stress")
        XCTAssertEqual(o.stress[0].confidence, 2, "read natively: high confidence")
        XCTAssertEqual(o.blamedDimensions, ["cpu"], "a nearly full disk's standing score must not put blame on disk")
    }

    func testDiskSaturation() throws {
        let o = try replay("disk")                       // uncached reads of a 512 MB file for 60 s
        XCTAssertEqual(o.episodes.count, 1)
        XCTAssertEqual(o.episodes[0].dominant, "disk")
        XCTAssertTrue((40...75).contains(o.episodes[0].seconds), "\(o.episodes[0].seconds) s")
        XCTAssertEqual(o.stress.first?.rank, 1)
        XCTAssertGreaterThan(o.stress.first?.share ?? 0, 0.85)
        XCTAssertEqual(o.stress.first?.topProcess, "pmon-stress")
    }

    func testRepeatedBurstsAreOneEpisode() throws {
        let o = try replay("flapping")                   // 20 s on, 10 s off, four times
        XCTAssertEqual(o.episodes.count, 1, "the pauses are shorter than the calm period, so it is one slowdown")
        XCTAssertEqual(o.episodes[0].dominant, "cpu")
        XCTAssertTrue((80...130).contains(o.episodes[0].seconds), "\(o.episodes[0].seconds) s")
        XCTAssertEqual(o.stress.first?.rank, 1)
        XCTAssertGreaterThan(o.stress.first?.share ?? 0, 0.8)
    }

    func testMemorySpike() throws {
        // 4 GB of incompressible memory on an 8 GB machine. The kernel absorbed it within seconds
        // (compressing and swapping other apps), so this is a short spike, not sustained thrashing.
        let o = try replay("memory")
        XCTAssertEqual(o.episodes.count, 1)
        XCTAssertEqual(o.episodes[0].dominant, "memory")
        XCTAssertLessThan(o.episodes[0].seconds, 30)
        XCTAssertEqual(o.stress.first?.rank, 1)
        XCTAssertGreaterThan(o.stress.first?.share ?? 0, 0.5, "it holds the most and all of the recent growth")
        XCTAssertEqual(o.stress.first?.topProcess, "pmon-stress")
        XCTAssertTrue(o.blamedDimensions.contains("disk"), "swapping shows up as disk pressure too")
    }

    func testCpuAndMemoryTogether() throws {
        let o = try replay("mixed")                      // 16 threads for 55 s plus a 3.5 GB allocation
        XCTAssertEqual(o.episodes.count, 1)
        XCTAssertEqual(o.episodes[0].dominant, "cpu", "CPU contention lasted the whole time; the memory spike was brief")
        XCTAssertEqual(o.stress.first?.rank, 1)
        XCTAssertGreaterThan(o.stress.first?.share ?? 0, 0.85)
    }

    func testReplayingAScenarioTwiceGivesIdenticalResults() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/scenarios/cpu.jsonl.gz", withExtension: nil))
        let dir = tempDir(self)
        let a = try Database(path: dir + "/a.db"), b = try Database(path: dir + "/b.db")
        try Replayer.replay(recording: url.path, into: a)
        try Replayer.replay(recording: url.path, into: b)
        for (table, order) in [("sys_sample", "sample_id"), ("app_sample", "sample_id, app_id"), ("proc_sample", "sample_id, proc_id"),
                               ("episode", "episode_id"), ("episode_blame", "episode_id, app_id, dim"), ("event", "event_id")] {
            XCTAssertEqual(try dump(a, table, orderBy: order), try dump(b, table, orderBy: order), table)
        }
    }
}
