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
    let pipeline = try Pipeline(db: db, host: host)
    let recorder = try recordPath.map { try Recorder(path: $0, host: host, capMB: config.recordingCapMB) }
    // The top stream covers processes of other users; without it, ps does (at higher cost).
    let topStream = config.topStreamEnabled
        ? TopStream(intervalSeconds: Int(config.foreignIntervalSeconds), pidFile: dbPath + ".top.pid") : nil
    topStream?.start()
    let collectors = LiveCollectors(topStream: topStream)

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
            // Self-limiting: stretch the process sweep interval while the daemon is over budget.
            if pipeline.backoffLevel != appliedBackoff {
                appliedBackoff = pipeline.backoffLevel
                schedulerRef?.setIntervals(systemSeconds: config.systemIntervalSeconds,
                                           processSeconds: config.processIntervalSeconds * pipeline.backoffMultiplier,
                                           slowSeconds: config.slowIntervalSeconds)
                Log.info("self-limiter level \(appliedBackoff): process interval \(config.processIntervalSeconds * pipeline.backoffMultiplier) s")
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
    dispatchMain()
} catch {
    Log.error("fatal: \(error)")
    exit(1)
}
