import Foundation
import Darwin
import IOKit
import IOKit.ps

/// A source of raw readings. Collectors read and return; they never compute deltas or interpret.
public protocol Collector {
    associatedtype Reading
    var tier: Tier { get }
    func collect() -> Reading
}

enum Sysctl {
    static func int(_ name: String) -> Int64? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}

/// CPU ticks, load, memory, pressure, swap, disk and network: the 5-second system tier.
public struct SystemCollector: Collector {
    public let tier = Tier.system
    public init() {}

    public func collect() -> SystemReading {
        var r = SystemReading()
        r.cores = Self.coreTicks()
        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) > 0 { r.load1 = load[0] }
        r.vm = Self.vm()
        r.pressureLevel = Int(Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 0)
        r.memLevelPct = Int(Sysctl.int("kern.memorystatus_level") ?? 0)
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            r.swapUsed = swap.xsu_used; r.swapTotal = swap.xsu_total
        }
        r.disk = Self.disk()
        r.net = Self.net()
        return r
    }

    static func coreTicks() -> [CoreTicks] {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.size))
        }
        return (0..<Int(n)).map { i in
            let b = i * Int(CPU_STATE_MAX)
            return CoreTicks(user: UInt32(bitPattern: info[b + Int(CPU_STATE_USER)]),
                             sys: UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)]),
                             idle: UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)]),
                             nice: UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)]))
        }
    }

    static func vm() -> VMReading {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var r = VMReading()
        guard rc == KERN_SUCCESS else { return r }
        r.freePages = UInt64(s.free_count); r.activePages = UInt64(s.active_count)
        r.inactivePages = UInt64(s.inactive_count); r.wiredPages = UInt64(s.wire_count)
        r.compressorPages = UInt64(s.compressor_page_count)
        r.compressedPages = s.total_uncompressed_pages_in_compressor
        r.faults = s.faults; r.pageins = s.pageins; r.pageouts = s.pageouts
        r.swapins = s.swapins; r.swapouts = s.swapouts
        r.compressions = s.compressions; r.decompressions = s.decompressions
        return r
    }

    static func disk() -> DiskReading {
        var r = DiskReading()
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return r }
        defer { IOObjectRelease(it) }
        while true {
            let entry = IOIteratorNext(it)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            func get(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }
            r.readBytes += get("Bytes (Read)"); r.writeBytes += get("Bytes (Write)")
            r.readOps += get("Operations (Read)"); r.writeOps += get("Operations (Write)")
            r.ioTimeNs += get("Total Time (Read)") + get("Total Time (Write)")
        }
        return r
    }

    /// 64-bit interface counters via the routing sysctl (getifaddrs counters are 32-bit and wrap at 4 GB).
    static func net() -> NetReading {
        var r = NetReading()
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return r }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return r }
        buf.withUnsafeBytes { p in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = p.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = p.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if Int32(h2.ifm_data.ifi_type) != IFT_LOOP {
                        r.inBytes += h2.ifm_data.ifi_ibytes
                        r.outBytes += h2.ifm_data.ifi_obytes
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return r
    }
}

/// Volume space, battery, power and thermal state: the 60-second slow tier.
public struct SlowCollector: Collector {
    public let tier = Tier.slow
    public init() {}

    public func collect() -> SlowReading {
        var r = SlowReading()
        let keys: [URLResourceKey] = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsLocalKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true,
                  let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacity, total > 0 else { continue }
            r.volumes.append(VolumeReading(mount: url.path, total: UInt64(total), free: UInt64(free)))
        }
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let providing = IOPSGetProvidingPowerSourceType(blob).takeUnretainedValue() as String
        r.onBattery = providing == kIOPMBatteryPowerKey
        for src in IOPSCopyPowerSourcesList(blob).takeRetainedValue() as [CFTypeRef] {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            r.batteryPct = cur * 100 / max
        }
        r.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: r.thermalLevel = 0
        case .fair: r.thermalLevel = 1
        case .serious: r.thermalLevel = 2
        case .critical: r.thermalLevel = 3
        @unknown default: r.thermalLevel = 0
        }
        return r
    }
}

public extension HostInfo {
    /// Read the static facts of this machine and boot.
    static func current() -> HostInfo {
        var h = HostInfo()
        h.model = Sysctl.string("hw.model") ?? ""
        h.chip = Sysctl.string("machdep.cpu.brand_string") ?? ""
        h.memBytes = UInt64(Sysctl.int("hw.memsize") ?? 0)
        h.pageSize = UInt64(vm_kernel_page_size)
        h.timebaseNum = MachTime.timebase.num; h.timebaseDen = MachTime.timebase.den
        let ncpu = Int(Sysctl.int("hw.logicalcpu") ?? 0)
        let eCount = Int(Sysctl.int("hw.perflevel1.logicalcpu") ?? 0)
        h.coreIsPerformance = (0..<ncpu).map { i in
            // The device tree names each core's cluster; fall back to "efficiency cores come first".
            let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus/cpu\(i)")
            defer { if entry != 0 { IOObjectRelease(entry) } }
            if entry != 0,
               let data = IORegistryEntryCreateCFProperty(entry, "cluster-type" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data, let c = data.first {
                return c == UInt8(ascii: "P")
            }
            return i >= eCount
        }
        h.pCores = h.coreIsPerformance.filter { $0 }.count
        h.eCores = ncpu - h.pCores
        h.bootSessionUUID = Sysctl.string("kern.bootsessionuuid") ?? ""
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 {
            h.bootTsMs = Int64(tv.tv_sec) * 1000 + Int64(tv.tv_usec) / 1000
        }
        let v = ProcessInfo.processInfo.operatingSystemVersion
        h.osVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        h.osBuild = Sysctl.string("kern.osversion") ?? ""
        return h
    }
}
