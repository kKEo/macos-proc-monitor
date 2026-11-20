import ArgumentParser
import Foundation
import Darwin
import PmonCore

/// Synthetic loads with known size, used to check what pmon reports. A test tool, not shipped.
@main
struct Stress: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pmon-stress",
        abstract: "Generate a known CPU, memory, disk or process-churn load.",
        subcommands: [Cpu.self, Memory.self, Disk.self, ForkStorm.self])
}

func nowNs() -> UInt64 { MachTime.ns(mach_absolute_time()) }

enum QoSName: String, ExpressibleByArgument, CaseIterable {
    case background, utility, `default`, userInitiated, userInteractive
    var qos: QualityOfService {
        switch self {
        case .background: return .background
        case .utility: return .utility
        case .default: return .default
        case .userInitiated: return .userInitiated
        case .userInteractive: return .userInteractive
        }
    }
}

struct Cpu: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Spin busy threads.")
    @Option(help: "Number of busy threads.") var threads = 4
    @Option(help: "Duration in seconds.") var seconds: Double = 20
    @Option(help: "Thread QoS: \(QoSName.allCases.map(\.rawValue).joined(separator: ", ")).") var qos = QoSName.userInitiated

    func run() {
        let end = nowNs() + UInt64(seconds * 1e9)
        let group = DispatchGroup()
        for _ in 0..<threads {
            group.enter()
            let t = Thread {
                var x: UInt64 = 1
                while nowNs() < end { for _ in 0..<200_000 { x = x &* 6364136223846793005 &+ 1442695040888963407 } }
                if x == 0 { print("") }
                group.leave()
            }
            t.qualityOfService = qos.qos
            t.start()
        }
        print("pid \(getpid()): \(threads) busy threads at \(qos.rawValue) QoS for \(seconds) s")
        group.wait()
    }
}

struct Memory: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Hold memory that the compressor cannot shrink.")
    @Option(help: "Megabytes to allocate.") var mb = 512
    @Option(help: "Seconds to hold it.") var seconds: Double = 20
    @Option(help: "Megabytes allocated per second (0 = all at once).") var rate = 0
    @Flag(help: "Fill with zeros instead of random bytes (compressible).") var compressible = false
    @Option(help: "While holding, re-read all of it every this many seconds (0 = never). Forces compressed or swapped memory back in.")
    var touchEvery: Double = 0

    func run() {
        let chunkMB = rate > 0 ? min(rate, mb) : mb
        var chunks: [UnsafeMutableRawPointer] = []
        var allocated = 0
        print("pid \(getpid()): allocating \(mb) MB (\(compressible ? "compressible" : "incompressible")), holding \(seconds) s")
        while allocated < mb {
            let size = chunkMB << 20                        // uniform chunks keep the re-touch loop simple
            let p = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16384)
            if compressible { memset(p, 0, size) } else { arc4random_buf(p, size) }
            chunks.append(p); allocated += size >> 20
            if rate > 0, allocated < mb { Thread.sleep(forTimeInterval: 1) }
        }
        let end = nowNs() + UInt64(seconds * 1e9)
        var sum: UInt64 = 0
        while nowNs() < end {
            guard touchEvery > 0 else { Thread.sleep(forTimeInterval: Double(end - nowNs()) / 1e9); break }
            Thread.sleep(forTimeInterval: min(touchEvery, Double(end - min(end, nowNs())) / 1e9))
            for c in chunks {                              // one byte per page is enough to fault it in
                var off = 0
                while off < chunkMB << 20 { sum &+= UInt64(c.load(fromByteOffset: off, as: UInt8.self)); off += 16384 }
            }
        }
        if sum == 1 { print("") }
        for c in chunks { c.deallocate() }
    }
}

struct Disk: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Write an uncached scratch file once, then read it back repeatedly (reads cause no SSD wear).")
    @Option(help: "Megabytes per pass.") var mb = 512
    @Option(help: "Run for at least this many seconds.") var seconds: Double = 20
    @Option(help: "Scratch file path.") var path = NSTemporaryDirectory() + "pmon-stress-\(getpid()).bin"

    func run() throws {
        let chunk = 4 << 20
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16384)
        defer { buf.deallocate(); unlink(path) }
        arc4random_buf(buf, chunk)
        let end = nowNs() + UInt64(seconds * 1e9)
        var passes = 0
        print("pid \(getpid()): writing \(mb) MB at \(path), then reading it for \(seconds) s")
        let fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0o600)
        guard fd >= 0 else { throw ValidationError("cannot open \(path)") }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        for _ in 0..<(mb / 4) { _ = write(fd, buf, chunk) }
        fsync(fd)
        repeat {
            lseek(fd, 0, SEEK_SET)
            while read(fd, buf, chunk) > 0, nowNs() < end {}
            passes += 1
        } while nowNs() < end
        print("\(mb) MB written once, read \(passes) times")
    }
}

struct ForkStorm: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start many short-lived processes.")
    @Option(help: "Processes started per second.") var rate = 50
    @Option(help: "Duration in seconds.") var seconds: Double = 20
    @Option(help: "CPU each child burns before exiting, in milliseconds.") var burnMs = 20

    func run() throws {
        let end = nowNs() + UInt64(seconds * 1e9)
        // A shell counting loop: roughly `burnMs` of CPU per child, with no dependencies.
        let script = "i=0; while [ $i -lt \(burnMs * 400) ]; do i=$((i+1)); done"
        var started = 0
        print("pid \(getpid()): starting \(rate) short-lived processes per second for \(seconds) s")
        while nowNs() < end {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", script]
            try p.run()
            started += 1
            // Do not wait: children overlap, like a build tool spawning compilers.
            Thread.sleep(forTimeInterval: 1.0 / Double(max(rate, 1)))
        }
        print("\(started) processes started")
    }
}
