// Phase 0 probes. Each subcommand answers one question from PLAN.md phase 0. Throwaway code.
import Foundation
import Darwin
import AppKit
import CoreServices

func me() -> rusage_info_v6 { rusage(getpid())! }
func cpuRaw(_ r: rusage_info_v6) -> UInt64 { r.ri_user_time + r.ri_system_time }
func sec(_ machUnits: UInt64) -> Double { Double(machToNs(machUnits)) / 1e9 }

// 0.2.2 — are rusage CPU times in Mach units, and does the timebase conversion give real time?
func probeTimebase() {
    var a = timespec(), b = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &a)
    let r0 = me()
    spin(threads: 1, seconds: 3, qos: .userInitiated)
    let r1 = me()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &b)
    let ref = Double(b.tv_sec - a.tv_sec) * 1e9 + Double(b.tv_nsec - a.tv_nsec)
    let raw = Double(cpuRaw(r1) - cpuRaw(r0))
    let conv = Double(machToNs(cpuRaw(r1) - cpuRaw(r0)))
    print("timebase \(timebase.num)/\(timebase.den)  reference_cpu_s=\(f(ref / 1e9, 3))  raw/ref=\(f(raw / ref, 4))  converted/ref=\(f(conv / ref, 4))")
    verdict("timebase", abs(conv / ref - 1) < 0.05, "converted rusage CPU time is \(f(conv / ref * 100, 1)) % of the reference; raw value is \(f(raw / ref * 100, 1)) %")
}

// 0.2.1 — does ri_runnable_time measure time threads spent waiting for a core?
func probeRunnable(_ out: String) {
    let csv = CSV(out, header: "threads,wall_s,cpu_s,cores_used,runnable_s,cores_waiting,expected_waiting,p_share,sys_busy_cores")
    let ncpu = ProcessInfo.processInfo.activeProcessorCount
    var worst = 0.0
    for n in [2, 4, 8, 16, 32] {
        let r0 = me(), t0 = nowNs(), k0 = cpuTicks()
        spin(threads: n, seconds: 6, qos: .userInitiated)
        let r1 = me(), t1 = nowNs(), k1 = cpuTicks()
        let wall = Double(t1 - t0) / 1e9
        let cpu = sec(cpuRaw(r1) - cpuRaw(r0))
        let run = sec(r1.ri_runnable_time - r0.ri_runnable_time)
        let pcpu = sec((r1.ri_user_ptime + r1.ri_system_ptime) - (r0.ri_user_ptime + r0.ri_system_ptime))
        let busy = Double((k1.user + k1.sys) - (k0.user + k0.sys)) / 100.0 / wall
        let expected = max(0, Double(n) - cpu / wall)
        csv.row([n, f(wall), f(cpu), f(cpu / wall), f(run), f(run / wall), f(expected), f(pcpu / max(cpu, 0.001)), f(busy)])
        print("threads=\(n)  cores_used=\(f(cpu / wall))  cores_waiting(runnable)=\(f(run / wall))  expected_waiting=\(f(expected))  p_core_share=\(f(pcpu / max(cpu, 0.001)))  system_busy_cores=\(f(busy))")
        if n > ncpu { worst = max(worst, abs(run / wall - expected) / expected) }
    }
    verdict("runnable_time", worst < 0.25, "when oversubscribed, runnable time differs from expected wait by at most \(f(worst * 100, 0)) %")
}

// 0.2.5 — does CPU time land in the per-QoS counter matching the thread's QoS, and where does it run?
func probeQoS(_ out: String) {
    let csv = CSV(out, header: "qos,cpu_s,default,maintenance,background,utility,legacy,user_initiated,user_interactive,p_share")
    let cases: [(String, QualityOfService)] = [("background", .background), ("utility", .utility), ("default", .default),
                                               ("userInitiated", .userInitiated), ("userInteractive", .userInteractive)]
    var ok = true
    for (name, q) in cases {
        let a = me()
        spin(threads: 4, seconds: 3, qos: q)
        let b = me()
        let cpu = sec(cpuRaw(b) - cpuRaw(a))
        let d: [(String, Double)] = [
            ("default", sec(b.ri_cpu_time_qos_default - a.ri_cpu_time_qos_default)),
            ("maintenance", sec(b.ri_cpu_time_qos_maintenance - a.ri_cpu_time_qos_maintenance)),
            ("background", sec(b.ri_cpu_time_qos_background - a.ri_cpu_time_qos_background)),
            ("utility", sec(b.ri_cpu_time_qos_utility - a.ri_cpu_time_qos_utility)),
            ("legacy", sec(b.ri_cpu_time_qos_legacy - a.ri_cpu_time_qos_legacy)),
            ("userInitiated", sec(b.ri_cpu_time_qos_user_initiated - a.ri_cpu_time_qos_user_initiated)),
            ("userInteractive", sec(b.ri_cpu_time_qos_user_interactive - a.ri_cpu_time_qos_user_interactive))]
        let p = sec((b.ri_user_ptime + b.ri_system_ptime) - (a.ri_user_ptime + a.ri_system_ptime)) / max(cpu, 0.001)
        let top = d.max { $0.1 < $1.1 }!
        csv.row([name, f(cpu)] + d.map { f($0.1) } + [f(p)])
        print("qos=\(name)  cpu_s=\(f(cpu))  largest_bucket=\(top.0) (\(f(top.1)) s)  p_core_share=\(f(p))")
        if top.0 != name || top.1 < cpu * 0.8 { ok = false }
    }
    verdict("qos_buckets", ok, ok ? "each QoS lands in its own counter" : "at least one QoS class did not land in the matching counter")
}

// 0.2.3 — how do the memory pressure signals move while memory is consumed?
func probeMem(_ out: String, stepMB: Int, capMB: Int) {
    let csv = CSV(out, header: "t_s,phase,alloc_mb,pressure_level,mem_level_pct,free_mb,compressor_mb,swap_used_mb,d_pageins,d_pageouts,d_swapins,d_swapouts,d_compressions,d_decompressions,own_footprint_mb")
    let page = Double(vm_kernel_page_size) / 1048576.0
    let t0 = nowNs()
    var prev = vmStats()
    var alloc = 0
    var maxSwapOut: UInt64 = 0, maxDecomp: UInt64 = 0, minLevel: Int64 = 100, maxPressure: Int64 = 0
    func sample(_ phase: String) {
        let s = vmStats()
        let lvl = sysctlInt("kern.memorystatus_vm_pressure_level") ?? -1
        let pct = sysctlInt("kern.memorystatus_level") ?? -1
        let so = s.swapouts - prev.swapouts, dc = s.decompressions - prev.decompressions
        maxSwapOut = max(maxSwapOut, so); maxDecomp = max(maxDecomp, dc); minLevel = min(minLevel, pct); maxPressure = max(maxPressure, lvl)
        csv.row([f(Double(nowNs() - t0) / 1e9, 1), phase, alloc, lvl, pct, f(Double(s.free_count) * page, 0),
                 f(Double(s.compressor_page_count) * page, 0), swapUsage().used >> 20,
                 s.pageins - prev.pageins, s.pageouts - prev.pageouts, s.swapins - prev.swapins, so,
                 s.compressions - prev.compressions, dc, me().ri_phys_footprint >> 20])
        prev = s
    }
    let startLevel = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
    let startPct = sysctlInt("kern.memorystatus_level") ?? 50
    print("start: pressure_level=\(startLevel) mem_level=\(startPct)%  step=\(stepMB)MB cap=\(capMB)MB")
    for _ in 0..<5 { sample("baseline"); sleep(1) }
    var chunks: [UnsafeMutableRawPointer] = []
    var reason = "cap reached"
    while alloc < capMB {
        chunks.append(allocIncompressible(mb: stepMB)); alloc += stepMB
        sample("alloc"); sleep(1); sample("alloc")
        let lvl = sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        let pct = sysctlInt("kern.memorystatus_level") ?? 50
        if lvl != startLevel { reason = "pressure level changed \(startLevel) -> \(lvl)"; break }
        if pct <= max(8, startPct - 30) { reason = "memory level fell to \(pct)%"; break }
    }
    print("stopped allocating at \(alloc) MB: \(reason)")
    for _ in 0..<3 { sample("hold"); sleep(1) }
    var sum: UInt64 = 0
    for c in chunks { sum &+= touch(c, mb: stepMB) }   // force early chunks back in
    sample("retouch"); sleep(1); sample("retouch")
    for c in chunks { c.deallocate() }
    chunks.removeAll(); alloc = 0
    for _ in 0..<8 { sample("freed"); sleep(1) }
    print("peak: pressure_level=\(maxPressure)  min_mem_level=\(minLevel)%  max_swapouts/s=\(maxSwapOut)  max_decompressions/s=\(maxDecomp)  (checksum \(sum & 0xff))")
    print("end: pressure_level=\(sysctlInt("kern.memorystatus_vm_pressure_level") ?? -1) mem_level=\(sysctlInt("kern.memorystatus_level") ?? -1)%")
}

// 0.2.4 — is IOKit "Total Time" usable as a disk saturation signal?
final class Phase { var name = "idle"; var stop = false }
func probeDisk(_ out: String, scratch: String, mb: Int) {
    let csv = CSV(out, header: "t_s,phase,read_mb_s,write_mb_s,read_ops_s,write_ops_s,busy_pct")
    let ph = Phase()
    let done = DispatchSemaphore(value: 0)
    var agg: [String: (busy: Double, n: Double, mb: Double)] = [:]
    let lock = NSLock()
    let sampler = Thread {
        var p = diskStats(); var tp = nowNs(); let t0 = tp
        while !ph.stop {
            usleep(500_000)
            let s = diskStats(); let t = nowNs(); let dt = Double(t - tp) / 1e9
            let busy = Double((s.rtNs - p.rtNs) + (s.wtNs - p.wtNs)) / 1e9 / dt * 100
            let rmb = Double(s.rb - p.rb) / 1048576 / dt, wmb = Double(s.wb - p.wb) / 1048576 / dt
            csv.row([f(Double(t - t0) / 1e9, 1), ph.name, f(rmb, 1), f(wmb, 1), f(Double(s.ro - p.ro) / dt, 0), f(Double(s.wo - p.wo) / dt, 0), f(busy, 1)])
            lock.lock(); var a = agg[ph.name] ?? (0, 0, 0); a.busy += busy; a.n += 1; a.mb += rmb + wmb; agg[ph.name] = a; lock.unlock()
            p = s; tp = t
        }
        done.signal()
    }
    sampler.start()
    print("drivers with statistics: \(diskStats().drivers)")
    sleep(4)
    ph.name = "write"; let w = writeFile(scratch, mb: mb)
    ph.name = "idle2"; sleep(3)
    ph.name = "read"; let r = readFile(scratch)
    ph.name = "idle3"; sleep(3)
    ph.stop = true; done.wait()
    unlink(scratch)
    print("write \(mb) MB in \(f(w)) s (\(f(Double(mb) / w, 0)) MB/s), read in \(f(r)) s (\(f(Double(mb) / r, 0)) MB/s)")
    for k in ["idle", "write", "idle2", "read", "idle3"] {
        if let a = agg[k] { print("phase=\(k)  mean_busy_pct=\(f(a.busy / a.n, 1))  mean_mb_s=\(f(a.mb / a.n, 1))") }
    }
    let idle = (agg["idle"].map { $0.busy / $0.n } ?? 0), wr = (agg["write"].map { $0.busy / $0.n } ?? 0), rd = (agg["read"].map { $0.busy / $0.n } ?? 0)
    verdict("disk_busy_time", wr > idle + 20 && rd > idle + 20, "busy % idle=\(f(idle, 1)) write=\(f(wr, 1)) read=\(f(rd, 1))")
}

// 0.3.2 helper — dump native cumulative counters for own processes.
func probeSweep(_ out: String) {
    let csv = CSV(out, header: "epoch_ms,pid,cpu_ns,footprint,idle_wkups,instructions,cycles,pageins")
    let t0 = nowNs(); var n = 0, denied = 0
    for pid in allPids() {
        guard let r = rusage(pid) else { denied += 1; continue }
        csv.row([wallMs(), pid, machToNs(cpuRaw(r)), r.ri_phys_footprint, r.ri_pkg_idle_wkups, r.ri_instructions, r.ri_cycles, r.ri_pageins]); n += 1
    }
    print("sweep: \(n) readable, \(denied) denied, \(f(Double(nowNs() - t0) / 1e6)) ms")
}

// 0.4.1 — can a UI-less process see app activation, input idle time and screen lock?
func probeSession(_ out: String, seconds: Double) {
    let csv = CSV(out, header: "epoch_ms,kind,value")
    csv.row([wallMs(), "start", "pid=\(getpid()) ppid=\(getppid())"])
    let nc = NSWorkspace.shared.notificationCenter
    nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { n in
        let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        csv.row([wallMs(), "activated", app?.bundleIdentifier ?? "?"])
    }
    for (name, label) in [(NSWorkspace.screensDidSleepNotification, "screens_sleep"), (NSWorkspace.screensDidWakeNotification, "screens_wake"),
                          (NSWorkspace.willSleepNotification, "will_sleep"), (NSWorkspace.didWakeNotification, "did_wake")] {
        nc.addObserver(forName: name, object: nil, queue: .main) { _ in csv.row([wallMs(), label, ""]) }
    }
    Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        csv.row([wallMs(), "poll", "idle_s=\(f(idle, 1)) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?") locked=\(locked) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) lowpower=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"])
    }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    csv.row([wallMs(), "end", ""])
}

// 0.4.2 — detect sleep from the gap between absolute and continuous time; record timer lateness.
func probeSleepWatch(_ out: String, seconds: Double, interval: Double) {
    let csv = CSV(out, header: "epoch_ms,abs_s,cont_s,slept_s_total,slept_s_delta,timer_late_ms")
    let a0 = nowNs(), c0 = contNs()
    var prevSlept = 0.0
    var next = Double(a0) / 1e9 + interval
    let end = Double(a0) / 1e9 + seconds
    while Double(nowNs()) / 1e9 < end {
        let wait = next - Double(nowNs()) / 1e9
        if wait > 0 { usleep(UInt32(wait * 1e6)) }
        let a = nowNs(), c = contNs()
        let slept = Double(c - c0) / 1e9 - Double(a - a0) / 1e9
        csv.row([wallMs(), f(Double(a - a0) / 1e9, 2), f(Double(c - c0) / 1e9, 2), f(slept, 2), f(slept - prevSlept, 2), f((Double(a) / 1e9 - next) * 1000, 1)])
        prevSlept = slept
        next += interval
        if next < Double(a) / 1e9 { next = Double(a) / 1e9 + interval }
    }
}

// 0.4.3 — do FSEvents arrive for the diagnostic report directories?
func probeFSEvents(seconds: Double) {
    let user = NSHomeDirectory() + "/Library/Logs/DiagnosticReports"
    let dirs = [user, "/Library/Logs/DiagnosticReports"]
    for d in dirs {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
        let sampleFile = items.first { $0.hasSuffix(".diag") || $0.hasSuffix(".ips") }
        var head = "unreadable"
        if let s = sampleFile, let fh = FileHandle(forReadingAtPath: d + "/" + s) { head = "\(fh.readData(ofLength: 200).count) bytes read from \(s)" }
        print("dir \(d): \(items.count) entries, sample header: \(head)")
    }
    let seenPtr = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    seenPtr.pointee = 0
    let cb: FSEventStreamCallback = { _, info, n, paths, _, _ in
        let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
        for p in arr { print("fsevent: \(p)") }
        info!.assumingMemoryBound(to: Int.self).pointee += n
    }
    var ctx = FSEventStreamContext(version: 0, info: UnsafeMutableRawPointer(seenPtr), retain: nil, release: nil, copyDescription: nil)
    let s = FSEventStreamCreate(nil, cb, &ctx, dirs as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))!
    FSEventStreamSetDispatchQueue(s, .main)
    let started = FSEventStreamStart(s)
    print("stream started: \(started)")
    let testFile = user + "/pmon-probe-test.tmp"
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { FileManager.default.createFile(atPath: testFile, contents: Data("x".utf8)) }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { try? FileManager.default.removeItem(atPath: testFile) }
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    FSEventStreamStop(s); FSEventStreamInvalidate(s)
    let seen = seenPtr.pointee
    verdict("fsevents", seen > 0, "\(seen) events received for a file created in the user DiagnosticReports directory")
}

@main struct Main {
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let a = CommandLine.arguments
        let out = "out"
        switch a.count > 1 ? a[1] : "" {
        case "timebase": probeTimebase()
        case "runnable": probeRunnable("\(out)/runnable.csv")
        case "qos": probeQoS("\(out)/qos.csv")
        case "mem": probeMem("\(out)/mem.csv", stepMB: Int(a[safe: 2] ?? "") ?? 256, capMB: Int(a[safe: 3] ?? "") ?? 2048)
        case "disk": probeDisk("\(out)/disk.csv", scratch: "\(out)/scratch.bin", mb: Int(a[safe: 2] ?? "") ?? 1024)
        case "sweep": probeSweep(a[safe: 2] ?? "\(out)/sweep.csv")
        case "session": probeSession(a[safe: 2] ?? "\(out)/session.csv", seconds: Double(a[safe: 3] ?? "") ?? 30)
        case "sleepwatch": probeSleepWatch("\(out)/sleepwatch.csv", seconds: Double(a[safe: 2] ?? "") ?? 3000, interval: 5)
        case "fsevents": probeFSEvents(seconds: 5)
        default: print("usage: probe timebase|runnable|qos|mem [stepMB capMB]|disk [MB]|sweep [csv]|session [csv seconds]|sleepwatch [seconds]|fsevents")
        }
    }
}

extension Array { subscript(safe i: Int) -> Element? { i < count ? self[i] : nil } }
