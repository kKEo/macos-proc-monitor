import Foundation

/// Turns raw tick records into stored rows: deltas, attribution, aggregation, then one
/// transaction per tick.
///
/// The pipeline has no access to collectors or clocks. Everything it knows arrives in a
/// `TickRecord`, so a live run and a replay of its recording produce identical rows.
public final class Pipeline {
    private let db: Database
    private let host: HostInfo
    private let writer: Writer
    private let procStore: ProcStore
    private let appStore: AppStore
    private let selection = Selection()
    private var systemDeltas = SystemDeltaEngine()
    private var procDeltas = ProcDeltaEngine()
    private var limiter = SelfLimiter()
    private var topDeltas = TopDeltaEngine()
    private var psDeltas = PsDeltaEngine()
    private var lastSlow: SlowReading?

    /// Monotonic time of the previous process sweep, and system totals accumulated since then.
    private var lastSweepMonoNs: UInt64?
    private var busyMsSinceSweep: Int64 = 0
    private var diskReadSinceSweep: Int64 = 0, diskWriteSinceSweep: Int64 = 0
    private var busyCoversSweep = false
    private var sweeps = 0

    /// Cumulative system busy CPU and readable-process CPU over time, to line them up with top samples.
    private var busySeries = CumulativeSeries()
    private var ownSeries = CumulativeSeries()
    private var lastTopMonoNs: UInt64?
    /// Recent process ticks (sample id and the interval each covers), so data that arrives late
    /// from the top stream can be credited to the ticks it actually belongs to.
    private var recentTicks: [(id: Int64, start: UInt64, end: UInt64)] = []

    // Context: last observed values, to turn changes into events.
    private var lastSession: SessionReading?
    private var lastPressure: Int?
    private var focusAppId: Int64?
    private var focusInitialised = false

    // Scoring, episodes and blame.
    private let thresholds: Thresholds
    private var scorer: Scorer
    private var detector: EpisodeDetector
    private let episodes: EpisodeStore
    private let blame: BlameCalculator
    private var summary: EpisodeSummary?
    private var lastWaitShare: Double?
    private var lastWakeTs: Int64?
    private var lastHang: (ts: Int64, appId: Int64?)?
    private var hangApps: [Int64] = []
    /// Episodes whose blame is recomputed once late top-stream data has arrived.
    private var pendingBlame: [(id: Int64, start: Int64, end: Int64, means: [String: Double], hangApps: [Int64], due: Int64)] = []

    // Housekeeping: rollups every minute, findings and retention every hour.
    private let rollup: Rollup
    private let retention: Retention
    private let findings: Findings
    private var lastMaintenanceMinute: Int64?
    private var lastBaselineDay: Int64?
    private var retentionBacklog = false
    private var needsVacuum = false

    // Optional collectors.
    /// Cumulative GPU time per pid at the previous process sweep; nil when the collector was not running then.
    private var gpuPrev: [Int32: UInt64]?
    private var lastOwn: (deltas: [ProcDelta], dtMs: Int64, selfPid: Int32?)?
    private var captureRequest: CaptureRequest?
    private var unknownCpuShare: Double?

    /// Set when an episode opens: what the capture collectors should look at. Returned once.
    public func takeCaptureRequest() -> CaptureRequest? {
        defer { captureRequest = nil }
        return captureRequest
    }

    /// CPU that could not be attributed to any process in the latest measurement, as a share of
    /// one core. Returned once per measurement; a high value is the cue for a short-lived process scan.
    public func takeUnknownCpuShare() -> Double? {
        defer { unknownCpuShare = nil }
        return unknownCpuShare
    }

    /// True while an episode is open or may be forming: the driver then samples at the fast
    /// cadence and asks `ps` for other users' processes on every sweep.
    public var wantsFastCadence: Bool { detector.wantsFastCadence }

    /// Counts for health reporting.
    public private(set) var ticksIngested = 0
    public private(set) var samplesWritten = 0
    /// Current self-limiter level (0 = normal). The driver stretches the process interval by `backoffMultiplier`.
    public var backoffLevel: Int { limiter.level }
    public var backoffMultiplier: Double { limiter.intervalMultiplier }

    public init(db: Database, host: HostInfo, thresholds: Thresholds = Thresholds(), retention policy: RetentionPolicy = RetentionPolicy()) throws {
        self.db = db
        self.host = host
        self.thresholds = thresholds
        scorer = Scorer(thresholds: thresholds)
        detector = EpisodeDetector(thresholds: thresholds)
        episodes = EpisodeStore(db: db)
        blame = BlameCalculator(db: db, thresholds: thresholds)
        rollup = Rollup(db: db)
        retention = Retention(db: db, policy: policy)
        findings = Findings(db: db)
        try Migrations.migrate(db)
        let bootId: Int64 = try db.transaction {
            try Dimensions.upsertHost(db, host)
            return try Dimensions.bootId(db, host)
        }
        writer = Writer(db: db, bootId: bootId, pageSize: Int64(host.pageSize))
        procStore = try ProcStore(db: db, bootId: bootId)
        appStore = AppStore(db: db)
        try db.transaction { try episodes.closeDangling() }
    }

    public func ingest(_ rec: TickRecord) throws {
        ticksIngested += 1
        if let slow = rec.slow { lastSlow = slow }
        try db.transaction {
            try ingestInTransaction(rec)
            try maintain(ts: rec.tick.wallMs)
        }
        // Give freed pages back to the file system, a little at a time. Not possible inside a transaction.
        if needsVacuum {
            needsVacuum = false
            try? db.exec("PRAGMA incremental_vacuum(1000)")
        }
    }

    /// Rollups once a minute; findings, baselines and retention when an hour completes, and
    /// once right after start-up. Driven by tick time, so a replay does exactly the same.
    private func maintain(ts: Int64) throws {
        let minute = ts / 60_000
        guard minute != lastMaintenanceMinute else { return }
        let firstRun = lastMaintenanceMinute == nil
        lastMaintenanceMinute = minute
        let advanced = try rollup.run(now: ts)
        if advanced.contains("1h") || firstRun {
            let day = ts / 86_400_000
            if day != lastBaselineDay { try findings.updateBaselines(now: ts); lastBaselineDay = day }
            try findings.run(now: ts, machineApp: procStore.machineApp)
        }
        if advanced.contains("1h") || firstRun || retentionBacklog {
            retentionBacklog = try retention.run(now: ts, rolledUpTo: try rollup.watermark("1m"))
            needsVacuum = true
        }
    }

    // MARK: - One tick

    private func ingestInTransaction(_ rec: TickRecord) throws {
        let tick = rec.tick

        // Dimension rows first: they are valid whether or not this tick yields a sample.
        if let sweep = rec.procs {
            let started = try procStore.apply(identities: sweep.identities, ts: tick.wallMs)
            let present = Set(sweep.procs.map(\.uid)).union(sweep.foreign.map(\.uid))
            let quit = try procStore.markExited(present: present, ts: tick.wallMs)
            // The first sweep describes everything already running; that is not a launch.
            if sweeps > 0 {
                for s in started { try writer.insertEvent(ts: tick.wallMs, kind: "proc_start", value: nil, detail: nil, appId: s.appId, procId: s.procId) }
                for q in quit { try writer.insertEvent(ts: tick.wallMs, kind: "proc_exit", value: nil, detail: nil, appId: q.appId, procId: q.procId) }
            }
            sweeps += 1
            if sweeps % 30 == 0 { try procStore.touchLive(ts: tick.wallMs) }
        }

        for note in rec.notes ?? [] {
            let target = try (note.exePath != nil || note.procName != nil) ? procStore.lookup(exePath: note.exePath, name: note.procName) : nil
            try writer.insertEvent(ts: tick.wallMs, kind: note.kind, value: note.value, detail: note.detail,
                                   appId: target?.appId, procId: target?.procId)
            if note.kind == "hang" { lastHang = (tick.wallMs, target?.appId) }
        }
        for c in rec.captures ?? [] {
            let procId = c.pid.flatMap { procStore.uidByPidLive[$0] }.flatMap { procStore.procIds[$0] }
            try writer.insertCapture(ts: tick.wallMs, c, procId: procId)
        }
        if let scan = rec.shortLived { try recordShortLived(scan, ts: tick.wallMs) }
        try updateContext(rec, ts: tick.wallMs)

        // An interval that spans sleep is not a real interval: drop every baseline so the next
        // tick starts fresh, and leave a flagged marker row so the gap is explained.
        if tick.afterWake {
            try writer.insertEvent(ts: tick.wallMs, kind: "wake", value: Int64(tick.sleptNs / 1_000_000_000), detail: nil)
            // Sleep ends an episode: whatever was slow before is not what is slow after.
            if let end = detector.forceClose() { try closeEpisode(endTs: end, now: tick.wallMs) }
            scorer.reset(); lastWaitShare = nil
            lastWakeTs = tick.wallMs
            resetBaselines()
            if let sys = rec.system {
                _ = systemDeltas.delta(sys, coreIsPerformance: host.coreIsPerformance)
                busySeries.anchor(at: tick.monoNs)
            }
            if let sweep = rec.procs {
                _ = procDeltas.deltas(sweep.procs, monoNs: tick.monoNs)
                ownSeries.anchor(at: tick.monoNs)
                lastSweepMonoNs = tick.monoNs; busyCoversSweep = true
                let uidByPid = Self.foreignMap(sweep)
                if let top = rec.top { _ = topDeltas.deltas(top, uidByPid: uidByPid); lastTopMonoNs = top.monoNs }
                if let ps = rec.ps { _ = psDeltas.deltas(ps, uidByPid: uidByPid) }
            }
            _ = try writer.insertSample(tick: tick, tier: 1, flags: .afterWake)
            samplesWritten += 1
            return
        }

        let sysDelta = rec.system.flatMap { systemDeltas.delta($0, coreIsPerformance: host.coreIsPerformance) }
        if let d = sysDelta {
            busyMsSinceSweep += d.cpuUserMs + d.cpuSysMs
            diskReadSinceSweep += d.diskRead; diskWriteSinceSweep += d.diskWrite
            busySeries.add(Double(d.cpuUserMs + d.cpuSysMs), at: tick.monoNs)
        } else {
            busyCoversSweep = false
            if rec.system != nil { busySeries.reset(); busySeries.anchor(at: tick.monoNs) }
        }

        // Natively read processes.
        var deltas: [ProcDelta] = []
        var totals: ProcTotals?
        var procDtMs: Int64?
        var residualDisk: (read: Int64, write: Int64)?
        let sweepStart = lastSweepMonoNs
        if let sweep = rec.procs {
            deltas = procDeltas.deltas(sweep.procs, monoNs: tick.monoNs).deltas
            if let last = lastSweepMonoNs {
                procDtMs = Int64((tick.monoNs - last) / 1_000_000)
                let cpuMs = Int64(deltas.reduce(UInt64(0)) { $0 + $1.cpuNs } / 1_000_000)
                ownSeries.add(Double(cpuMs), at: tick.monoNs)
                if busyCoversSweep {
                    residualDisk = (max(0, diskReadSinceSweep - deltas.reduce(0) { $0 + $1.dDiskRead }),
                                    max(0, diskWriteSinceSweep - deltas.reduce(0) { $0 + $1.dDiskWrite }))
                }
                // Foreground wait: each process's wait, scaled by the foreground share of its CPU time.
                let fgWait = deltas.reduce(0.0) { $0 + Double($1.waitMs) * ($1.cpuMs > 0 ? min(1, Double($1.cpuFgMs) / Double($1.cpuMs)) : 1) }
                lastWaitShare = fgWait / (Double(max(procDtMs!, 1)) * Double(max(host.coreIsPerformance.count, 1)))
                totals = ProcTotals(procCount: sweep.procs.count + sweep.foreign.count,
                                    threadCount: sweep.procs.reduce(0) { $0 + Int($1.threads) },
                                    waitMs: deltas.reduce(0) { $0 + $1.waitMs }, fgWaitMs: Int64(fgWait.rounded()),
                                    unattributedCpuMs: busyCoversSweep ? max(0, busyMsSinceSweep - cpuMs) : nil,
                                    unattributedDiskBytes: residualDisk.map { $0.read + $0.write })
                try observeSelfCost(sweep: sweep, deltas: deltas, selfPid: rec.selfPid, procDtMs: procDtMs!, ts: tick.wallMs)
            } else {
                ownSeries.anchor(at: tick.monoNs)
            }
            lastSweepMonoNs = tick.monoNs
        }

        // Processes of other users: top stream and/or ps, merged into one set of rows.
        var foreign: [ForeignDelta] = []
        var foreignDtMs: Int64?
        var topWindow: (start: UInt64, end: UInt64)?
        var psActive = false
        var flags: SampleFlags = backoffLevel > 0 ? .degraded : []
        if let sweep = rec.procs {
            let uidByPid = Self.foreignMap(sweep)
            var rows: [UInt64: ForeignDelta] = [:]

            if let top = rec.top, let r = topDeltas.deltas(top, uidByPid: uidByPid) {
                rows = r.rows; foreignDtMs = r.dtMs; flags.insert(.foreignFresh)
                if let last = lastTopMonoNs { topWindow = (last, top.monoNs) }
            }
            // ps supplies CPU at the process cadence. While it is active it is the only CPU source,
            // so CPU already reported by ps is not counted again when a top sample arrives.
            let ps = rec.ps.flatMap { psDeltas.deltas($0, uidByPid: uidByPid) }
            if rec.ps == nil { psDeltas.reset() }
            if let ps {
                psActive = true
                flags.insert(.foreignCpuFromPs)
                for uid in rows.keys { rows[uid]!.cpuUserMs = nil; rows[uid]!.cpuSysMs = nil; rows[uid]!.cpuNs = 0 }
                for (uid, cpu) in ps {
                    var d = rows[uid] ?? ForeignDelta()
                    if rows[uid] == nil { d.uid = uid; d.fidelity = 2 }
                    d.cpuUserMs = cpu.userMs; d.cpuSysMs = cpu.sysMs; d.cpuNs = cpu.ns; d.cpuFromPs = true
                    rows[uid] = d
                }
            }
            // Sorted so that ties in the selection, and therefore a replay, come out the same every time.
            foreign = rows.values.sorted { $0.uid < $1.uid }

            // Residual: system busy CPU minus readable processes minus measured foreign processes.
            let foreignCpuMs = Double(foreign.reduce(UInt64(0)) { $0 + $1.cpuNs }) / 1e6
            if psActive, let notOwn = totals?.unattributedCpuMs {
                totals?.foreignCpuMs = Int64(foreignCpuMs.rounded())
                totals?.unknownCpuMs = notOwn - Int64(foreignCpuMs.rounded())
                if let dt = procDtMs, dt > 0 { unknownCpuShare = Double(totals!.unknownCpuMs!) / Double(dt) }
            } else if let top = rec.top, foreignDtMs != nil, totals != nil {
                totals?.foreignCpuMs = Int64(foreignCpuMs.rounded())
                // The top sample covers [previous top sample, this top sample], which does not line
                // up with ticks: read the cumulative system and own-process CPU at those two moments.
                if let last = lastTopMonoNs,
                   let b0 = busySeries.value(at: last), let b1 = busySeries.value(at: top.monoNs),
                   let o0 = ownSeries.value(at: last), let o1 = ownSeries.value(at: top.monoNs) {
                    totals?.unknownCpuMs = Int64(((b1 - b0) - (o1 - o0) - foreignCpuMs).rounded())
                    if top.monoNs > last { unknownCpuShare = Double(totals!.unknownCpuMs!) / (Double(top.monoNs - last) / 1e6) }
                }
            }
            if let top = rec.top { lastTopMonoNs = top.monoNs }
            busyMsSinceSweep = 0; diskReadSinceSweep = 0; diskWriteSinceSweep = 0; busyCoversSweep = true
        }

        guard let sys = rec.system, let d = sysDelta else {
            return   // first reading, or a counter reset: baselines only
        }
        // Score this sample and advance the episode state machine.
        let session = rec.session ?? lastSession
        let scores = scorer.score(scoreInput(tick: tick, reading: sys, delta: d, session: session))
        let transition = detector.observe(ts: tick.wallMs, index: scores.index)
        if detector.isOpen { flags.insert(.episodeOpen) }

        let id = try writer.insertSample(tick: tick, tier: rec.procs != nil ? 2 : 1, flags: flags,
                                         procDtMs: procDtMs, foreignDtMs: foreignDtMs)
        try writer.insertSystem(sampleId: id, tick: tick, reading: sys, delta: d, slow: lastSlow, procs: totals,
                                session: session, focusAppId: focusAppId, scores: scores, diskProbeUs: rec.slow?.diskProbeUs)

        // GPU time per process, when that collector is running: deltas between consecutive sweeps.
        var gpuByApp: [Int64: Int64] = [:]
        if rec.procs != nil {
            let now = rec.gpu.map { Dictionary($0.map { ($0.pid, $0.ns) }, uniquingKeysWith: { a, _ in a }) }
            if let now, let prev = gpuPrev {
                for (pid, ns) in now.sorted(by: { $0.key < $1.key }) {
                    // A client that closed takes its accumulated time with it, so a total can fall: no delta then.
                    guard let before = prev[pid], ns > before, let uid = procStore.uidByPidLive[pid],
                          let app = procStore.appIdByUid[uid] else { continue }
                    let ms = Int64((Double(ns - before) / 1e6).rounded())
                    if ms > 0 { gpuByApp[app, default: 0] += ms }
                }
            }
            gpuPrev = now
        }

        if let procDtMs {
            lastOwn = (deltas, procDtMs, rec.selfPid)
            for (delta, reason) in selection.select(own: deltas, selfPid: rec.selfPid, dtMs: procDtMs) {
                try procStore.insertSample(sampleId: id, delta, reason: reason)
            }
            // CPU from ps covers the process interval; everything from top covers the top interval.
            for (delta, reason) in selection.select(foreign: foreign, dtMs: psActive ? procDtMs : (foreignDtMs ?? 30_000)) {
                try procStore.insertForeign(sampleId: id, delta, reason: reason)
            }
            recentTicks.append((id, sweepStart ?? tick.monoNs, tick.monoNs))
            if recentTicks.count > 16 { recentTicks.removeFirst(recentTicks.count - 16) }
            try aggregateApps(sampleId: id, procDtMs: procDtMs, own: deltas, foreign: foreign, psActive: psActive,
                              topWindow: topWindow, unknownCpuMs: totals?.unknownCpuMs, residualDisk: residualDisk)
            for (app, ms) in gpuByApp.sorted(by: { $0.key < $1.key }) {
                var a = AppAgg(); a.gpuMs = ms
                try appStore.add(sampleId: id, appId: app, a, isFocus: app == focusAppId)
            }
        }
        if let slow = rec.slow { try writer.insertVolumes(sampleId: id, slow.volumes) }
        samplesWritten += 1

        // Episodes. Done last, so blame sees this tick's app rows.
        if case .opened(let start)? = transition {
            var s = EpisodeSummary()
            s.id = try episodes.open(startTs: start); s.startTs = start
            summary = s
            hangApps = []
            captureRequest = try makeCaptureRequest(episodeId: s.id, ts: tick.wallMs, scores: scores)
        }
        if summary != nil, transition.map({ if case .closed = $0 { return false } else { return true } }) ?? true {
            let present = session.map { $0.idleSeconds < thresholds.presentIdleSeconds && $0.displayOn && !$0.locked } ?? true
            summary!.add(dtMs: Int64(tick.dtNs / 1_000_000), scores: scores, present: present, focus: focusAppId,
                         session: session, active: scores.index >= thresholds.closeAt)
            if let hang = lastHang, let app = hang.appId, Double(tick.wallMs - hang.ts) <= thresholds.hangSeconds * 1000 { hangApps.append(app) }
        }
        if case .closed(let end)? = transition { try closeEpisode(endTs: end, now: tick.wallMs) }

        for p in pendingBlame where tick.wallMs >= p.due {
            let rows = try blame.compute(episodeId: p.id, start: p.start, end: p.end, meanScores: p.means, hangApps: p.hangApps)
            try episodes.replaceBlame(episodeId: p.id, rows, calculator: blame, start: p.start, end: p.end)
        }
        pendingBlame.removeAll { tick.wallMs >= $0.due }
    }

    /// Write the episode's summary and its blame. Blame is computed now and once more a minute
    /// later, when data from the top stream that covers the episode's last seconds has arrived.
    private func closeEpisode(endTs: Int64, now: Int64) throws {
        guard let s = summary else { return }
        summary = nil
        let afterWake = lastWakeTs.map { s.startTs - $0 >= 0 && s.startTs - $0 <= 60_000 } ?? false
        try episodes.close(s, endTs: max(endTs, s.startTs), afterWake: afterWake)
        let means = Dictionary(uniqueKeysWithValues: Scores.dimensions.map { ($0, s.mean($0)) })
        let rows = try blame.compute(episodeId: s.id, start: s.startTs, end: endTs, meanScores: means, hangApps: hangApps)
        try episodes.replaceBlame(episodeId: s.id, rows, calculator: blame, start: s.startTs, end: endTs)
        pendingBlame.append((s.id, s.startTs, endTs, means, hangApps, now + 60_000))
    }

    /// The processes worth a closer look when an episode opens: the busiest and the largest of
    /// the ones we can read, from the latest sweep.
    private func makeCaptureRequest(episodeId: Int64, ts: Int64, scores: Scores) throws -> CaptureRequest {
        let dominant = Scores.dimensions.max { scores.value($0) < scores.value($1) } ?? "cpu"
        guard let own = lastOwn else { return CaptureRequest(episodeId: episodeId, ts: ts, dominant: dominant, cpuTop: [], memTop: []) }
        func target(_ d: ProcDelta) throws -> CaptureTarget {
            var name = "pid \(d.pid)"
            if let procId = procStore.procIds[d.uid] {
                try db.query("SELECT e.name FROM process p JOIN executable e USING (exe_id) WHERE p.proc_id = ?", [procId]) { name = $0.text(0) }
            }
            return CaptureTarget(pid: d.pid, name: name, cpuShare: Double(d.cpuMs) / Double(max(own.dtMs, 1)), footprint: d.footprint)
        }
        let candidates = own.deltas.filter { $0.pid != own.selfPid }
        let cpu = candidates.filter { $0.cpuMs > 0 }.sorted { ($0.cpuMs, $1.uid) > ($1.cpuMs, $0.uid) }.prefix(5)
        let mem = candidates.sorted { ($0.footprint, $1.uid) > ($1.footprint, $0.uid) }.prefix(3)
        return CaptureRequest(episodeId: episodeId, ts: ts, dominant: dominant, cpuTop: try cpu.map(target), memTop: try mem.map(target))
    }

    /// One `short_lived` event per app whose processes started the churn, so blame can move
    /// unattributed CPU to it. Groups whose starter is unknown are recorded without an app.
    private func recordShortLived(_ scan: ShortLivedScan, ts: Int64) throws {
        struct Sum { var count = 0; var aliveMs: Int64 = 0, cpuMs: Int64 = 0; var parent = ""; var top: [(String, Int)] = [] }
        var byApp: [Int64: Sum] = [:]
        for g in scan.groups {
            let app = procStore.uidByPidLive[g.parentPid].flatMap { procStore.appIdByUid[$0] } ?? 0
            var s = byApp[app] ?? Sum()
            s.count += g.count; s.aliveMs += g.aliveMs; s.cpuMs += g.cpuMs
            if s.parent.isEmpty { s.parent = g.parentName }
            s.top.append((g.name, g.count))
            byApp[app] = s
        }
        for (app, s) in byApp.sorted(by: { $0.key < $1.key }) {
            let detail: [String: Any] = [
                "alive_ms": s.aliveMs, "scan_ms": scan.durationMs, "cpu_ms": s.cpuMs, "started_by": s.parent,
                "births": scan.births, "scan_cpu_ms": scan.costCpuMs,
                "top": s.top.prefix(5).map { ["name": $0.0, "count": $0.1] as [String: Any] },
            ]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys]), as: UTF8.self)
            try writer.insertEvent(ts: ts, kind: "short_lived", value: Int64(s.count), detail: json, appId: app == 0 ? nil : app)
        }
        if scan.groups.isEmpty {
            try writer.insertEvent(ts: ts, kind: "short_lived", value: 0,
                                   detail: #"{"births":\#(scan.births),"scan_cpu_ms":\#(scan.costCpuMs),"scan_ms":\#(scan.durationMs)}"#)
        }
    }

    private func scoreInput(tick: Tick, reading sys: SystemReading, delta d: SystemDelta, session: SessionReading?) -> ScoreInput {
        let dtMs = Double(max(tick.dtNs / 1_000_000, 1))
        let pCores = Double(max(host.coreIsPerformance.filter { $0 }.count, 1))
        var x = ScoreInput()
        x.pBusyShare = Double(d.pBusyMs) / (dtMs * pCores)
        x.waitShare = lastWaitShare
        x.canaryMs = Double(tick.lateNs) / 1e6
        x.pressureLevel = sys.pressureLevel
        x.memLevelPct = sys.memLevelPct
        x.thrash = Double(d.decompressions + d.pageins + 4 * (d.swapins + d.swapouts)) / (dtMs / 1000)
        x.queueDepth = Double(d.diskIoTimeMs) / dtMs
        if let v = lastSlow?.volumes.first(where: { $0.mount == "/" }) ?? lastSlow?.volumes.first, v.total > 0 {
            x.diskFreePct = Double(v.free) / Double(v.total) * 100
        }
        x.gpuUtilPct = sys.gpuUtilPct.map(Double.init)
        x.thermalLevel = session?.thermalLevel ?? lastSlow?.thermalLevel ?? 0
        if let hang = lastHang {
            x.hangAgeSeconds = Double(tick.wallMs - hang.ts) / 1000
            x.hangIsFocus = hang.appId != nil && hang.appId == focusAppId
        }
        return x
    }

    private static func foreignMap(_ sweep: ProcSweep) -> [Int32: UInt64] {
        Dictionary(sweep.foreign.map { ($0.pid, $0.uid) }, uniquingKeysWith: { a, _ in a })
    }

    private func resetBaselines() {
        systemDeltas.reset(); procDeltas.reset(); topDeltas.reset(); psDeltas.reset()
        busySeries.reset(); ownSeries.reset()
        lastTopMonoNs = nil; lastSweepMonoNs = nil
        busyMsSinceSweep = 0; diskReadSinceSweep = 0; diskWriteSinceSweep = 0; busyCoversSweep = false
        recentTicks.removeAll()
        gpuPrev = nil; lastOwn = nil
    }

    // MARK: - Apps

    /// Write `app_sample`: every app's activity, complete, so its sums match the system totals.
    private func aggregateApps(sampleId: Int64, procDtMs: Int64, own: [ProcDelta], foreign: [ForeignDelta], psActive: Bool,
                               topWindow: (start: UInt64, end: UInt64)?, unknownCpuMs: Int64?,
                               residualDisk: (read: Int64, write: Int64)?) throws {
        // Natively read processes: this tick, exact interval.
        var ownApps: [Int64: AppAgg] = [:]
        for d in own {
            guard let app = procStore.appIdByUid[d.uid] else { continue }
            ownApps[app, default: AppAgg()].add(own: d)
        }
        var other = AppAgg()
        for (app, agg) in ownApps {
            if agg.significant(dtMs: procDtMs) || app == focusAppId {
                try appStore.add(sampleId: sampleId, appId: app, agg, isFocus: app == focusAppId)
            } else {
                other.add(agg)
            }
        }
        if other.procCount > 0 { try appStore.add(sampleId: sampleId, appId: procStore.otherApp, other, isFocus: false) }

        // Other users' processes. CPU from ps belongs to this tick. Everything from a top sample
        // covers the top interval, which spans several ticks: it is split across them.
        var direct: [Int64: AppAgg] = [:], spread: [Int64: AppAgg] = [:]
        for d in foreign {
            guard let app = procStore.appIdByUid[d.uid] else { continue }
            if d.cpuFromPs {
                var a = AppAgg(); a.cpuMs = (d.cpuUserMs ?? 0) + (d.cpuSysMs ?? 0); a.fidelity = 2
                direct[app, default: AppAgg()].add(a)
            }
            if d.fidelity == 1 {
                var a = AppAgg(); a.procCount = 1; a.fidelity = 1
                if !d.cpuFromPs { a.cpuMs = d.cpuUserMs }
                a.footprint = d.footprint; a.dFootprint = d.dFootprint; a.pageins = d.dPageins; a.wakeups = d.dWakeups
                spread[app, default: AppAgg()].add(a)
            }
        }
        if let ms = unknownCpuMs, ms > 0 {
            var a = AppAgg(); a.cpuMs = ms; a.fidelity = 3
            if psActive { direct[procStore.unattributedApp, default: AppAgg()].add(a) }
            else { spread[procStore.unattributedApp, default: AppAgg()].add(a) }
        }
        if let disk = residualDisk, disk.read + disk.write > 0 {
            var a = AppAgg(); a.diskRead = disk.read; a.diskWrite = disk.write; a.fidelity = 3
            direct[procStore.foreignResidualApp, default: AppAgg()].add(a)
        }
        for (app, agg) in direct { try appStore.add(sampleId: sampleId, appId: app, agg, isFocus: app == focusAppId) }

        guard !spread.isEmpty else { return }
        let slices = Self.slices(of: topWindow, over: recentTicks, current: sampleId)
        let windowMs = topWindow.map { Int64(($0.end - $0.start) / 1_000_000) } ?? procDtMs
        var otherSpread = AppAgg()
        for (app, agg) in spread {
            if agg.significant(dtMs: windowMs) || app == focusAppId || app == procStore.unattributedApp {
                for s in slices { try appStore.add(sampleId: s.id, appId: app, agg.slice(from: s.from, to: s.to, gauges: s.gauges), isFocus: app == focusAppId) }
            } else {
                otherSpread.add(agg)
            }
        }
        if otherSpread.procCount > 0 {
            for s in slices { try appStore.add(sampleId: s.id, appId: procStore.otherApp, otherSpread.slice(from: s.from, to: s.to, gauges: s.gauges), isFocus: false) }
        }
    }

    /// How a top interval divides over the process ticks it overlaps, as cumulative fractions.
    /// Any part that predates the oldest known tick is shared among the ticks that are known.
    ///
    /// `gauges` marks the ticks that should receive point-in-time values (footprint, process
    /// count): those whose end lies inside the window. A tick straddling two windows gets counter
    /// shares from both but its gauges from exactly one, so nothing is counted twice.
    static func slices(of window: (start: UInt64, end: UInt64)?, over ticks: [(id: Int64, start: UInt64, end: UInt64)],
                       current: Int64) -> [(id: Int64, from: Double, to: Double, gauges: Bool)] {
        guard let w = window else { return [(current, 0, 1, true)] }
        var parts: [(id: Int64, len: Double, gauges: Bool)] = []
        for t in ticks {
            let lo = max(t.start, w.start), hi = min(t.end, w.end)
            if hi > lo { parts.append((t.id, Double(hi - lo), t.end > w.start && t.end <= w.end)) }
        }
        let total = parts.reduce(0) { $0 + $1.len }
        guard total > 0 else { return [(current, 0, 1, true)] }
        var out: [(id: Int64, from: Double, to: Double, gauges: Bool)] = []
        var acc = 0.0
        for (i, p) in parts.enumerated() {
            let next = i == parts.count - 1 ? 1.0 : acc + p.len / total
            out.append((p.id, acc, next, p.gauges))
            acc = next
        }
        return out
    }

    // MARK: - Context and events

    /// Turn changes in session state and memory pressure into events, and keep the focus span current.
    private func updateContext(_ rec: TickRecord, ts: Int64) throws {
        if let sys = rec.system {
            if let last = lastPressure, last != sys.pressureLevel {
                try writer.insertEvent(ts: ts, kind: "pressure", value: Int64(sys.pressureLevel), detail: nil)
            }
            lastPressure = sys.pressureLevel
        }
        guard let s = rec.session else { return }

        if let p = lastSession {
            if p.thermalLevel != s.thermalLevel { try writer.insertEvent(ts: ts, kind: "thermal", value: Int64(s.thermalLevel), detail: nil) }
            if p.onBattery != s.onBattery { try writer.insertEvent(ts: ts, kind: "power", value: s.onBattery ? 1 : 0, detail: nil) }
            if p.lowPower != s.lowPower { try writer.insertEvent(ts: ts, kind: "low_power", value: s.lowPower ? 1 : 0, detail: nil) }
            if p.displayOn != s.displayOn { try writer.insertEvent(ts: ts, kind: "display", value: s.displayOn ? 1 : 0, detail: nil) }
            if p.locked != s.locked { try writer.insertEvent(ts: ts, kind: "lock", value: s.locked ? 1 : 0, detail: nil) }
        }
        lastSession = s

        // Focus: the app of the frontmost regular application. A frontmost process we have not
        // identified yet (it started since the last sweep) leaves the focus unchanged for now.
        var newFocus = focusAppId
        if let pid = s.frontPid {
            if let uid = procStore.uidByPidLive[pid], let app = procStore.appIdByUid[uid] { newFocus = app }
        } else {
            newFocus = nil
        }
        if !focusInitialised || newFocus != focusAppId {
            // On the first reading this also closes a span left open by a previous run.
            try writer.setFocus(appId: newFocus, ts: ts)
            if focusInitialised { try writer.insertEvent(ts: ts, kind: "focus", value: nil, detail: nil, appId: newFocus) }
            focusAppId = newFocus
            focusInitialised = true
        }
    }

    /// Feed the self-limiter and record a change of level as an event.
    private func observeSelfCost(sweep: ProcSweep, deltas: [ProcDelta], selfPid: Int32?, procDtMs: Int64, ts: Int64) throws {
        let selfCpu = selfPid.flatMap { pid in deltas.first { $0.pid == pid }?.cpuMs }
        let sweepMs = Double(sweep.durationNs) / 1e6
        guard limiter.observe(sweepMs: sweepMs, selfCpuMs: selfCpu, dtMs: procDtMs) else { return }
        let share = limiter.cpuShare.map { String(format: "%.4f", $0) } ?? "null"
        try writer.insertEvent(ts: ts, kind: "collector_backoff", value: Int64(limiter.level),
                               detail: #"{"level":\#(limiter.level),"sweep_ms":\#(String(format: "%.1f", sweepMs)),"cpu_share":\#(share)}"#)
    }
}
