import XCTest
@testable import PmonCore

/// Sanity checks against the real machine: values are present and plausible.
final class CollectorTests: XCTestCase {
    func testSystemCollectorReadsPlausibleValues() {
        let r = SystemCollector().collect()
        XCTAssertEqual(r.cores.count, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertTrue(r.cores.allSatisfy { $0.idle > 0 })
        XCTAssertGreaterThan(r.vm.freePages + r.vm.activePages + r.vm.wiredPages, 0)
        XCTAssertGreaterThan(r.vm.faults, 0)
        XCTAssertTrue([1, 2, 4].contains(r.pressureLevel), "pressure level \(r.pressureLevel)")
        XCTAssertTrue((1...100).contains(r.memLevelPct))
        XCTAssertGreaterThan(r.disk.readBytes, 0)
        XCTAssertGreaterThan(r.disk.ioTimeNs, 0)
        XCTAssertGreaterThan(r.net.inBytes + r.net.outBytes, 0)
    }

    func testCountersAreMonotonicBetweenReads() {
        let a = SystemCollector().collect()
        Thread.sleep(forTimeInterval: 0.3)
        let b = SystemCollector().collect()
        XCTAssertGreaterThanOrEqual(b.vm.faults, a.vm.faults)
        XCTAssertGreaterThanOrEqual(b.disk.readBytes, a.disk.readBytes)
        var engine = SystemDeltaEngine()
        let host = HostInfo.current()
        _ = engine.delta(a, coreIsPerformance: host.coreIsPerformance)
        let d = engine.delta(b, coreIsPerformance: host.coreIsPerformance)
        XCTAssertNotNil(d)
        let total = d!.cpuUserMs + d!.cpuSysMs + d!.cpuIdleMs
        let expected = Int64(300 * a.cores.count)
        XCTAssertTrue((expected / 2...expected * 2).contains(total), "core time \(total) ms for 0.3 s on \(a.cores.count) cores")
    }

    func testSlowCollectorAndHostInfo() {
        let s = SlowCollector().collect()
        XCTAssertFalse(s.volumes.isEmpty)
        XCTAssertTrue(s.volumes.allSatisfy { $0.total >= $0.free && $0.total > 0 })
        XCTAssertTrue((0...3).contains(s.thermalLevel))

        let h = HostInfo.current()
        XCTAssertFalse(h.model.isEmpty); XCTAssertFalse(h.bootSessionUUID.isEmpty)
        XCTAssertEqual(h.pCores + h.eCores, ProcessInfo.processInfo.activeProcessorCount)
        XCTAssertEqual(h.coreIsPerformance.count, h.pCores + h.eCores)
        XCTAssertGreaterThan(h.memBytes, 1 << 30)
        XCTAssertGreaterThan(h.bootTsMs, 0)
    }

    func testMachTimeConversion() {
        XCTAssertEqual(MachTime.ns(0), 0)
        let (num, den) = MachTime.timebase
        // 2^55 units is decades of uptime: a plain 64-bit multiply would overflow, full-width must not.
        let big: UInt64 = 1 << 55
        XCTAssertEqual(Double(MachTime.ns(big)), Double(big) * Double(num) / Double(den), accuracy: 1e6)
        XCTAssertEqual(MachTime.ns(3 * 1_000_000), 3 * 1_000_000 * num / den)
        // A result beyond 64 bits saturates instead of trapping.
        if num > den { XCTAssertEqual(MachTime.ns(.max), .max) }
    }
}
