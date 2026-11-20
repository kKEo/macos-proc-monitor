import Foundation
import IOKit

/// GPU readings from the accelerator's IORegistry entries. No privileges needed.
///
/// The property names are not a documented interface and have changed between OS releases, so
/// every read is optional: a missing key yields nil or an empty list, never an error.
public struct GpuCollector {
    public init() {}

    private func accelerators(_ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let entry = IOIteratorNext(it), entry != 0 {
            body(entry)
            IOObjectRelease(entry)
        }
    }

    /// Device utilisation in percent; the busiest device when there are several.
    public func utilisation() -> Int? {
        var best: Int?
        accelerators { entry in
            guard let stats = IORegistryEntryCreateCFProperty(entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any], let u = stats["Device Utilization %"] as? Int else { return }
            best = max(best ?? 0, u)
        }
        return best
    }

    /// Cumulative GPU time per process: each accelerator client names its creator ("pid 410,
    /// WindowServer") and lists the time its command queues have used.
    public func clients() -> [GpuClient] {
        var byPid: [Int32: UInt64] = [:]
        accelerators { entry in
            var kids: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &kids) == KERN_SUCCESS else { return }
            defer { IOObjectRelease(kids) }
            while case let kid = IOIteratorNext(kids), kid != 0 {
                defer { IOObjectRelease(kid) }
                guard let usage = IORegistryEntryCreateCFProperty(kid, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]], !usage.isEmpty,
                      let creator = IORegistryEntryCreateCFProperty(kid, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, let pid = Self.pid(fromCreator: creator) else { continue }
                let ns = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                byPid[pid, default: 0] += ns
            }
        }
        return byPid.map { GpuClient(pid: $0.key, ns: $0.value) }.sorted { $0.pid < $1.pid }
    }

    static func pid(fromCreator s: String) -> Int32? {
        guard s.hasPrefix("pid ") else { return nil }
        return Int32(s.dropFirst(4).prefix { $0.isNumber })
    }
}

/// Times one uncached read from a scratch file on the system volume. Reads only: no SSD wear
/// beyond creating the 1 MB file once.
public struct DiskProbe {
    let path: String
    public init(path: String) { self.path = path }

    public func measure() -> Int? {
        let size = 1 << 20, block = 16384
        if (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) != size {
            guard FileManager.default.createFile(atPath: path, contents: Data(count: size), attributes: [.posixPermissions: 0o600]) else { return nil }
        }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        _ = fcntl(fd, F_NOCACHE, 1)
        let buf = UnsafeMutableRawPointer.allocate(byteCount: block, alignment: block)
        defer { buf.deallocate() }
        let offset = off_t(Int.random(in: 0..<(size / block)) * block)
        let t0 = DispatchTime.now().uptimeNanoseconds
        guard pread(fd, buf, block, offset) == block else { return nil }
        return Int((DispatchTime.now().uptimeNanoseconds - t0) / 1000)
    }
}
