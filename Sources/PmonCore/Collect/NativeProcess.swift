import Foundation
import Darwin
import CPmonSys

/// Sweeps every process: native counters for the ones we may read, a reference for the rest,
/// and identity facts for instances not seen in the previous sweep.
///
/// Stateful only in remembering which instances it has already described, so that identity
/// (several syscalls and a path lookup) is read once per process rather than every sweep.
public final class NativeProcessCollector {
    private var known = Set<UInt64>()
    private var pidBuf = [pid_t](repeating: 0, count: 1024)
    private var pathBuf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))

    public init() {}

    public func collect() -> ProcSweep {
        let t0 = mach_absolute_time()
        var sweep = ProcSweep()
        var seen = Set<UInt64>()

        var n = Int(proc_listallpids(&pidBuf, Int32(pidBuf.count * MemoryLayout<pid_t>.size)))
        if n >= pidBuf.count {           // buffer was full: grow and retry once
            pidBuf = [pid_t](repeating: 0, count: pidBuf.count * 2)
            n = Int(proc_listallpids(&pidBuf, Int32(pidBuf.count * MemoryLayout<pid_t>.size)))
        }
        sweep.procs.reserveCapacity(max(n, 0))

        for i in 0..<max(n, 0) {
            let pid = pidBuf[i]
            var uid: UInt64 = 0, parentUid: UInt64 = 0
            guard pmon_unique_id(pid, &uid, &parentUid) == 0, seen.insert(uid).inserted else { continue }

            let own: Bool
            if let reading = Self.read(pid: pid, uid: uid) {
                sweep.procs.append(reading); own = true
            } else {
                sweep.foreign.append(ProcRef(pid: pid, uid: uid)); own = false
            }
            if !known.contains(uid), let ident = identity(pid: pid, uid: uid, parentUid: parentUid, own: own) {
                sweep.identities.append(ident)
            }
        }
        known = seen
        sweep.durationNs = MachTime.ns(mach_absolute_time() - t0)
        return sweep
    }

    /// Native counters of one process, or nil when the kernel refuses (another user's process) or it has exited.
    static func read(pid: pid_t, uid: UInt64) -> ProcReading? {
        var ri = rusage_info_v6()
        let rc = withUnsafeMutablePointer(to: &ri) { p in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        guard rc == 0 else { return nil }
        var r = ProcReading()
        r.pid = pid; r.uid = uid
        r.startNs = MachTime.ns(ri.ri_proc_start_abstime)
        r.userNs = MachTime.ns(ri.ri_user_time); r.sysNs = MachTime.ns(ri.ri_system_time)
        r.pNs = MachTime.ns(ri.ri_user_ptime + ri.ri_system_ptime)
        r.fgNs = MachTime.ns(ri.ri_cpu_time_qos_default + ri.ri_cpu_time_qos_legacy
                             + ri.ri_cpu_time_qos_user_initiated + ri.ri_cpu_time_qos_user_interactive)
        r.utilNs = MachTime.ns(ri.ri_cpu_time_qos_utility)
        r.bgNs = MachTime.ns(ri.ri_cpu_time_qos_background + ri.ri_cpu_time_qos_maintenance)
        r.runnableNs = MachTime.ns(ri.ri_runnable_time)
        r.footprint = ri.ri_phys_footprint; r.rss = ri.ri_resident_size
        r.pageins = ri.ri_pageins
        r.diskRead = ri.ri_diskio_bytesread; r.diskWrite = ri.ri_diskio_byteswritten
        r.energyNj = ri.ri_energy_nj
        r.idleWakeups = ri.ri_pkg_idle_wkups
        r.instructions = ri.ri_instructions

        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size {
            r.threads = ti.pti_threadnum
            r.csw = UInt32(bitPattern: ti.pti_csw)
        }
        return r
    }

    private func identity(pid: pid_t, uid: UInt64, parentUid: UInt64, own: Bool) -> ProcIdentity? {
        var basic = pmon_basic_t()
        guard pmon_proc_basic(pid, &basic) == 0 else { return nil }     // exited meanwhile
        var id = ProcIdentity()
        id.pid = pid; id.uid = uid; id.parentUid = parentUid; id.own = own
        id.ppid = basic.ppid; id.userId = basic.uid
        id.startTsMs = basic.start_sec * 1000 + Int64(basic.start_usec) / 1000
        id.translated = basic.flags & PMON_P_TRANSLATED != 0
        id.name = withUnsafeBytes(of: &basic.comm) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        if proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 { id.path = String(cString: pathBuf) }
        if id.path.isEmpty { id.path = pid == 0 ? "kernel_task" : id.name }   // the kernel has no executable path
        if id.name.isEmpty { id.name = (id.path as NSString).lastPathComponent }
        let responsible = pmon_responsible_pid(pid)
        if responsible > 0 { id.responsiblePid = responsible }
        var coalition: UInt64 = 0
        if pmon_coalition_id(pid, &coalition) == 0 { id.coalitionId = coalition }
        if let bundle = bundle(forExecutable: id.path) {
            id.bundlePath = bundle.path; id.bundleId = bundle.id; id.bundleName = bundle.name
        }
        return id
    }

    private var bundleCache: [String: (path: String, id: String?, name: String?)] = [:]

    /// The outermost `.app` bundle that contains `path`, with facts from its Info.plist.
    /// "Outermost" makes a browser's helper apps resolve to the browser itself.
    private func bundle(forExecutable path: String) -> (path: String, id: String?, name: String?)? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        if let hit = bundleCache[bundlePath] { return hit }
        let info = NSDictionary(contentsOfFile: bundlePath + "/Contents/Info.plist")
        let name = (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String)
        let result = (bundlePath, info?["CFBundleIdentifier"] as? String, name)
        bundleCache[bundlePath] = result
        return result
    }
}
