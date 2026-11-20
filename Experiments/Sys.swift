// Shared low-level helpers for the phase 0 probes. Throwaway code.
import Foundation
import Darwin
import IOKit

let timebase: (num: UInt64, den: UInt64) = {
    var i = mach_timebase_info_data_t()
    mach_timebase_info(&i)
    return (UInt64(i.numer), UInt64(i.denom))
}()

@inline(__always) func machToNs(_ t: UInt64) -> UInt64 { t * timebase.num / timebase.den }
func nowNs() -> UInt64 { machToNs(mach_absolute_time()) }
func contNs() -> UInt64 { machToNs(mach_continuous_time()) }
func wallMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func rusage(_ pid: pid_t) -> rusage_info_v6? {
    var ri = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &ri) { p in
        p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    return r == 0 ? ri : nil
}

func allPids() -> [pid_t] {
    let n = proc_listallpids(nil, 0)
    var buf = [pid_t](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<pid_t>.size))
    return buf.prefix(Int(max(got, 0))).filter { $0 > 0 }
}

func sysctlInt(_ name: String) -> Int64? {
    var v: Int64 = 0
    var sz = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &sz, nil, 0) == 0 else { return nil }
    return sz == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
}

func swapUsage() -> (total: UInt64, used: UInt64) {
    var x = xsw_usage()
    var sz = MemoryLayout<xsw_usage>.size
    sysctlbyname("vm.swapusage", &x, &sz, nil, 0)
    return (x.xsu_total, x.xsu_used)
}

func vmStats() -> vm_statistics64 {
    var s = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    _ = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    return s
}

struct CpuTicks { var user: UInt64 = 0, sys: UInt64 = 0, idle: UInt64 = 0 }

/// Summed CPU ticks over all cores (1 tick = 10 ms).
func cpuTicks() -> CpuTicks {
    var n: natural_t = 0
    var info: processor_info_array_t?
    var cnt: mach_msg_type_number_t = 0
    var t = CpuTicks()
    guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &cnt) == KERN_SUCCESS,
          let info else { return t }
    for i in 0..<Int(n) {
        let b = i * Int(CPU_STATE_MAX)
        t.user += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])) + UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        t.sys += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]))
        t.idle += UInt64(UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]))
    }
    vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(cnt) * MemoryLayout<integer_t>.size))
    return t
}

struct DiskStats { var rb: Int64 = 0, wb: Int64 = 0, rtNs: Int64 = 0, wtNs: Int64 = 0, ro: Int64 = 0, wo: Int64 = 0, drivers = 0 }

/// Summed IOBlockStorageDriver statistics over all physical devices.
func diskStats() -> DiskStats {
    var it: io_iterator_t = 0
    var t = DiskStats()
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return t }
    while true {
        let e = IOIteratorNext(it)
        if e == 0 { break }
        if let p = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
            func g(_ k: String) -> Int64 { (p[k] as? NSNumber)?.int64Value ?? 0 }
            t.rb += g("Bytes (Read)"); t.wb += g("Bytes (Write)")
            t.rtNs += g("Total Time (Read)"); t.wtNs += g("Total Time (Write)")
            t.ro += g("Operations (Read)"); t.wo += g("Operations (Write)")
            t.drivers += 1
        }
        IOObjectRelease(e)
    }
    IOObjectRelease(it)
    return t
}

final class CSV {
    private let fh: FileHandle
    init(_ path: String, header: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        fh = FileHandle(forWritingAtPath: path)!
        fh.write((header + "\n").data(using: .utf8)!)
    }
    func row(_ v: [Any]) { fh.write((v.map { "\($0)" }.joined(separator: ",") + "\n").data(using: .utf8)!) }
}

func verdict(_ name: String, _ ok: Bool, _ detail: String) {
    print("[\(ok ? "PASS" : "ADJUST")] \(name): \(detail)")
}

func f(_ x: Double, _ d: Int = 2) -> String { String(format: "%.\(d)f", x) }
