import Foundation
import Darwin
import PmonCore

// pmond — the pmon collection daemon. Runs as a per-user LaunchAgent; needs no privileges.

func usage() -> Never {
    print("""
        usage: pmond [--db <path>] [--config <path>] [--record <file>]
          --db      database file (default: \(PmonPaths.database))
          --config  configuration file (default: \(PmonPaths.config))
          --record  also write every raw reading to this file, for later replay
        """)
    exit(2)
}

var dbPath = PmonPaths.database
var configPath = PmonPaths.config
var recordPath: String?
var args = CommandLine.arguments.dropFirst().makeIterator()
func value(_ it: inout IndexingIterator<ArraySlice<String>>) -> String {
    guard let v = it.next() else { usage() }
    return v
}
while let a = args.next() {
    switch a {
    case "--db": dbPath = value(&args)
    case "--config": configPath = value(&args)
    case "--record": recordPath = value(&args)
    case "--version": print(PmonVersion.string); exit(0)
    default: usage()
    }
}

do {
    try PmonPaths.ensureSupportDir()

    // Single instance per database: hold an exclusive lock for the life of the process.
    let lockPath = PmonPaths.lock(forDatabase: dbPath)
    let lockFd = open(lockPath, O_CREAT | O_RDWR, 0o600)
    guard lockFd >= 0, flock(lockFd, LOCK_EX | LOCK_NB) == 0 else {
        Log.error("another pmond already holds \(lockPath); exiting")
        exit(1)
    }
    ftruncate(lockFd, 0)
    _ = "\(getpid())\n".withCString { write(lockFd, $0, strlen($0)) }

    let config = try Config.load(path: configPath)
    let host = HostInfo.current()
    let db = try Database(path: dbPath)
    let pipeline = try Pipeline(db: db, host: host, thresholds: config.thresholds, retention: config.retention)
    let recorder = try recordPath.map { try Recorder(path: $0, host: host, capMB: config.recordingCapMB) }
    // The top stream covers processes of other users; without it, ps does (at higher cost).
    let topStream = config.topStreamEnabled
        ? TopStream(intervalSeconds: Int(config.foreignIntervalSeconds), pidFile: dbPath + ".top.pid") : nil
    topStream?.start()
    let diagReports = DiagReportWatcher()
    diagReports.start()
    let captureDir = PmonPaths.captures(forDatabase: dbPath)
    // The root helper is optional: used when its socket answers, ignored otherwise.
    let helper = HelperClient(socketPath: config.helperSocket)
    if helper.connect() { Log.info("root helper \(helper.version ?? "?") found at \(config.helperSocket)") }
    let captures = CaptureManager(dir: captureDir, config: config.collectors, helper: helper)
    let scanner = ShortLivedScanner()
    let collectors = LiveCollectors(topStream: topStream, session: SessionCollector(), diagReports: diagReports,
                                    collectors: config.collectors, captures: captures, scanner: scanner,
                                    diskProbe: DiskProbe(path: captureDir + "/probe.bin"), helper: helper)
    var helperWasActive = false
    var lastBattery: Int?
    var lastScanMono: UInt64 = 0
    var lastExpiryMono: UInt64?
    let cadencePolicy = CadencePolicy(config: config)
    var cadence = cadencePolicy.decide(session: nil)

    var failures = 0
    var appliedBackoff = 0
    var schedulerRef: Scheduler?
    let planner = TickPlanner(systemSeconds: config.systemIntervalSeconds,
                              processSeconds: config.processIntervalSeconds,
                              slowSeconds: config.slowIntervalSeconds)
    let scheduler = Scheduler(clock: SystemClock(), planner: planner) { tick in
        let rec = collectors.collect(for: tick)
        do {
            try recorder?.append(rec)
            try pipeline.ingest(rec)
            failures = 0
            // The top child is not needed while the root helper answers; it resumes the moment it stops.
            if collectors.helperActive != helperWasActive {
                helperWasActive = collectors.helperActive
                Log.info(helperWasActive ? "root helper active: top stream paused" : "root helper gone: back to the top stream")
                if helperWasActive || cadence.pauseTop { topStream?.pause() } else { topStream?.resume() }
            }
            // Optional collectors: captures for a newly opened episode, and a scan for short-lived
            // processes when CPU goes unattributed. Both run off this queue.
            if let pct = rec.slow?.batteryPct { lastBattery = pct }
            if let req = pipeline.takeCaptureRequest() {
                captures.submit(req, onBattery: rec.session?.onBattery ?? false, batteryPct: lastBattery)
            }
            if let share = pipeline.takeUnknownCpuShare(), config.collectors.shortLived != .off,
               share >= config.collectors.shortLivedCpuShare, !scanner.isRunning {
                // Triggered: at most one scan every five minutes. Always: every thirty seconds while the condition holds.
                let gapNs: UInt64 = config.collectors.shortLived == .always ? 30_000_000_000 : 300_000_000_000
                if lastScanMono == 0 || tick.monoNs - lastScanMono >= gapNs {
                    lastScanMono = tick.monoNs
                    scanner.start()
                }
            }
            if rec.slow != nil, lastExpiryMono.map({ tick.monoNs - $0 >= 3_600_000_000_000 }) ?? true {
                lastExpiryMono = tick.monoNs
                captures.expire(maxAgeDays: config.retention.episodeDays)
            }
            // Cadence: sample less when nobody is watching (display off, user idle, low power), and
            // stretch the process sweep further while the daemon itself is over budget.
            let wanted = cadencePolicy.decide(session: rec.session ?? nil, fast: pipeline.wantsFastCadence)
            collectors.psBurst = pipeline.wantsFastCadence
            if (rec.session != nil && wanted != cadence) || pipeline.backoffLevel != appliedBackoff {
                if rec.session != nil, wanted != cadence {
                    cadence = wanted
                    collectors.addNote(CollectorNote(kind: "cadence", value: Int64(cadence.level), detail: #"{"mode":"\#(cadence.name)"}"#))
                    if cadence.pauseTop || helperWasActive { topStream?.pause() } else { topStream?.resume() }
                }
                appliedBackoff = pipeline.backoffLevel
                schedulerRef?.setIntervals(systemSeconds: cadence.systemSeconds,
                                           processSeconds: cadence.processSeconds * pipeline.backoffMultiplier,
                                           slowSeconds: cadence.slowSeconds)
                Log.info("cadence \(cadence.name), self-limiter level \(appliedBackoff): system \(cadence.systemSeconds) s, process \(cadence.processSeconds * pipeline.backoffMultiplier) s")
            }
        } catch {
            failures += 1
            // Log the first failure and then only occasionally, so a persistent fault cannot flood the log.
            if failures == 1 || failures % 100 == 0 { Log.error("tick \(tick.seq) failed (\(failures) in a row): \(error)") }
        }
    }

    schedulerRef = scheduler

    // Shut down cleanly on SIGTERM (launchd) and SIGINT (terminal).
    var signalSources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            scheduler.stop()
            topStream?.stop()
            diagReports.stop()
            recorder?.close()
            Log.info("stopped after \(pipeline.ticksIngested) ticks, \(pipeline.samplesWritten) samples")
            exit(0)
        }
        src.resume()
        signalSources.append(src)
    }

    Log.info("pmond \(PmonVersion.string) started: db=\(dbPath) system=\(config.systemIntervalSeconds)s process=\(config.processIntervalSeconds)s slow=\(config.slowIntervalSeconds)s"
             + (recordPath.map { " recording=\($0)" } ?? ""))
    scheduler.start()
    // A run loop (not just dispatchMain) so that app-activation notifications are delivered.
    RunLoop.main.run()
    exit(0)
} catch {
    Log.error("fatal: \(error)")
    exit(1)
}
