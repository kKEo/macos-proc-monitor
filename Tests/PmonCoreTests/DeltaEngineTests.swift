import XCTest
@testable import PmonCore

final class DeltaEngineTests: XCTestCase {
    let clusters = [false, false, true, true]

    func testFirstReadingIsBaselineOnly() {
        var engine = SystemDeltaEngine()
        XCTAssertNil(engine.delta(FakeMachine().reading, coreIsPerformance: clusters))
    }

    func testDeltasAndClusterSplit() {
        var engine = SystemDeltaEngine(), m = FakeMachine()
        _ = engine.delta(m.reading, coreIsPerformance: clusters)
        m.step()
        let d = engine.delta(m.reading, coreIsPerformance: clusters)!
        // 2 E cores at 50 busy ticks + 2 P cores at 200 busy ticks, 10 ms per tick.
        XCTAssertEqual(d.eBusyMs, 2 * 50 * 10)
        XCTAssertEqual(d.pBusyMs, 2 * 200 * 10)
        XCTAssertEqual(d.cpuUserMs + d.cpuSysMs, d.eBusyMs + d.pBusyMs)
        XCTAssertEqual(d.cpuUserMs + d.cpuSysMs + d.cpuIdleMs, 4 * 5000)      // 4 cores x 5 s
        XCTAssertEqual(d.pageins, 100); XCTAssertEqual(d.swapouts, 7); XCTAssertEqual(d.decompressions, 300)
        XCTAssertEqual(d.diskRead, 1 << 20); XCTAssertEqual(d.diskWrite, 2 << 20)
        XCTAssertEqual(d.diskOps, 30); XCTAssertEqual(d.diskIoTimeMs, 250)
        XCTAssertEqual(d.netIn, 4096); XCTAssertEqual(d.netOut, 1024)
    }

    func testTickCounterWrapIsHandled() {
        var engine = SystemDeltaEngine(), m = FakeMachine()
        for i in 0..<4 { m.reading.cores[i].idle = UInt32.max - 100 }      // about to wrap
        _ = engine.delta(m.reading, coreIsPerformance: clusters)
        m.step()
        let d = engine.delta(m.reading, coreIsPerformance: clusters)!
        XCTAssertEqual(d.cpuUserMs + d.cpuSysMs + d.cpuIdleMs, 4 * 5000)
        XCTAssertGreaterThan(d.cpuIdleMs, 0)
    }

    func testCounterResetSkipsOneIntervalThenRecovers() {
        var engine = SystemDeltaEngine(), m = FakeMachine()
        _ = engine.delta(m.reading, coreIsPerformance: clusters)
        m.step()
        XCTAssertNotNil(engine.delta(m.reading, coreIsPerformance: clusters))
        m.step()
        m.reading.net.inBytes = 10                      // interface went away: counter restarted
        XCTAssertNil(engine.delta(m.reading, coreIsPerformance: clusters), "a backwards counter must not produce a sample")
        m.step()
        let d = engine.delta(m.reading, coreIsPerformance: clusters)
        XCTAssertEqual(d?.netIn, 4096, "the reset reading becomes the new baseline")
    }

    func testResetDropsTheBaseline() {
        var engine = SystemDeltaEngine(), m = FakeMachine()
        _ = engine.delta(m.reading, coreIsPerformance: clusters)
        engine.reset()
        m.step()
        XCTAssertNil(engine.delta(m.reading, coreIsPerformance: clusters))
    }

    func testChangedCoreCountIsTreatedAsNewBaseline() {
        var engine = SystemDeltaEngine(), m = FakeMachine()
        _ = engine.delta(m.reading, coreIsPerformance: clusters)
        m.step()
        m.reading.cores.removeLast()
        XCTAssertNil(engine.delta(m.reading, coreIsPerformance: clusters))
    }
}
