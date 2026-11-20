import Foundation
import XCTest
@testable import PmonCore

/// A temporary directory removed when the test ends.
func tempDir(_ test: XCTestCase) -> String {
    let dir = NSTemporaryDirectory() + "pmon-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
    return dir
}

func testHost() -> HostInfo {
    var h = HostInfo()
    h.model = "TestMac1,1"; h.chip = "Test M1"; h.pCores = 2; h.eCores = 2
    h.memBytes = 8 << 30; h.pageSize = 16384; h.timebaseNum = 125; h.timebaseDen = 3
    h.coreIsPerformance = [false, false, true, true]
    h.bootSessionUUID = "TEST-BOOT-1"; h.bootTsMs = 1_799_000_000_000; h.osVersion = "26.2.0"; h.osBuild = "25C56"
    return h
}

/// A synthetic machine whose counters advance by known amounts each step.
struct FakeMachine {
    var reading = SystemReading()

    init() {
        reading.cores = Array(repeating: CoreTicks(user: 1000, sys: 500, idle: 100_000, nice: 0), count: 4)
        reading.load1 = 1.5; reading.pressureLevel = 1; reading.memLevelPct = 50
        reading.vm.freePages = 10_000; reading.vm.compressorPages = 20_000; reading.vm.compressedPages = 60_000
    }

    /// Advance 5 seconds: E cores 10 % busy, P cores 40 % busy, plus fixed I/O and paging activity.
    mutating func step() {
        for i in 0..<4 {
            let busy: UInt32 = i < 2 ? 50 : 200          // of 500 ticks per core
            reading.cores[i].user &+= busy - busy / 4      // user + sys must add up to exactly `busy`
            reading.cores[i].sys &+= busy / 4
            reading.cores[i].idle &+= 500 - busy
        }
        reading.vm.pageins += 100; reading.vm.swapouts += 7; reading.vm.decompressions += 300; reading.vm.faults += 5000
        reading.disk.readBytes += 1 << 20; reading.disk.writeBytes += 2 << 20
        reading.disk.readOps += 10; reading.disk.writeOps += 20; reading.disk.ioTimeNs += 250_000_000
        reading.net.inBytes += 4096; reading.net.outBytes += 1024
    }
}

/// Dump a table as text so two databases can be compared row for row.
func dump(_ db: Database, _ table: String, orderBy: String) throws -> [String] {
    var rows: [String] = []
    try db.query("SELECT * FROM \(table) ORDER BY \(orderBy)") { r in
        rows.append((0..<r.columnCount).map { r.isNull($0) ? "NULL" : r.text($0) }.joined(separator: "|"))
    }
    return rows
}
