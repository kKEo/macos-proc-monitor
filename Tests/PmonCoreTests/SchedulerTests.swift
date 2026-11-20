import XCTest
@testable import PmonCore

final class SchedulerTests: XCTestCase {
    func testFirstTickFiresEveryTierWithZeroInterval() {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        let t = planner.plan(clock: clock, deadlineNs: nil)
        XCTAssertEqual(t.seq, 0)
        XCTAssertEqual(Set(t.tiers), Set(Tier.allCases))
        XCTAssertEqual(t.dtNs, 0)
        XCTAssertFalse(t.afterWake)
    }

    func testTiersFireAtTheirOwnCadence() {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        var fired: [Tier: Int] = [:]
        for _ in 0..<25 {                       // 0 s ... 120 s
            let t = planner.plan(clock: clock, deadlineNs: nil)
            for tier in t.tiers { fired[tier, default: 0] += 1 }
            clock.advance(seconds: 5)
        }
        XCTAssertEqual(fired[.system], 25)
        XCTAssertEqual(fired[.process], 13)      // 0, 10, ... 120
        XCTAssertEqual(fired[.slow], 3)          // 0, 60, 120
    }

    func testJitterDoesNotSkipOrDoubleATier() {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        var process = 0
        let jitter = [0.0, 0.2, -0.15, 0.3, -0.25, 0.1, 0.0, -0.3, 0.25, 0.0, 0.2, -0.2]
        for j in jitter {
            if planner.plan(clock: clock, deadlineNs: nil).tiers.contains(.process) { process += 1 }
            clock.advance(seconds: 5 + j)
        }
        XCTAssertEqual(process, 6)               // every second tick of 12
    }

    func testIntervalAndLatenessAreMeasured() {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        _ = planner.plan(clock: clock, deadlineNs: nil)
        let deadline = planner.nextDeadline(now: clock.monotonicNs)
        clock.advance(seconds: 5.004)
        let t = planner.plan(clock: clock, deadlineNs: deadline)
        XCTAssertEqual(t.dtNs, 5_004_000_000)
        XCTAssertEqual(t.lateNs, 4_000_000)
        XCTAssertEqual(t.sleptNs, 0)
    }

    func testSleepIsDetectedAndExcludedFromTheInterval() {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        _ = planner.plan(clock: clock, deadlineNs: nil)
        clock.advance(seconds: 2)
        clock.sleep(seconds: 3600)
        clock.advance(seconds: 3)
        let t = planner.plan(clock: clock, deadlineNs: nil)
        XCTAssertTrue(t.afterWake)
        XCTAssertEqual(t.dtNs, 5_000_000_000)           // awake time only
        XCTAssertEqual(t.sleptNs, 3_600_000_000_000)
        clock.advance(seconds: 5)
        XCTAssertFalse(planner.plan(clock: clock, deadlineNs: nil).afterWake)
    }

    func testNextDeadlineNeverLiesInThePast() {
        let clock = FakeClock()
        var planner = TickPlanner(systemSeconds: 5, processSeconds: 10, slowSeconds: 60)
        _ = planner.plan(clock: clock, deadlineNs: nil)
        clock.advance(seconds: 42)               // the handler stalled
        XCTAssertEqual(planner.nextDeadline(now: clock.monotonicNs), clock.monotonicNs)
    }

    func testLiveSchedulerTicksAndStops() {
        let expect = expectation(description: "three ticks")
        expect.expectedFulfillmentCount = 3
        expect.assertForOverFulfill = false
        var seqs: [Int] = []
        let s = Scheduler(clock: SystemClock(), planner: TickPlanner(systemSeconds: 0.5, processSeconds: 1, slowSeconds: 60)) { tick in
            seqs.append(tick.seq); expect.fulfill()
        }
        s.start()
        wait(for: [expect], timeout: 5)
        s.stop()
        let count = seqs.count
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertEqual(seqs.count, count, "no ticks after stop")
        XCTAssertEqual(Array(seqs.prefix(3)), [0, 1, 2])
    }
}
