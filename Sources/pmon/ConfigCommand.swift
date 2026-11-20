import ArgumentParser
import Foundation
import PmonCore

/// What each optional collector is for, in the order they are listed.
private let collectorNotes: [(name: String, adds: String)] = [
    ("gpu", "GPU utilisation on every sample; feeds the GPU score"),
    ("gpuProcess", "GPU time per app; names the cause of a GPU slowdown"),
    ("stack", "call stacks of the busiest process when a slowdown starts"),
    ("threads", "threads and open files of the five busiest processes"),
    ("footprint", "memory composition of the largest process (memory slowdowns)"),
    ("shortLived", "names processes too short-lived for the regular sweep"),
    ("network", "network bytes per process during a slowdown"),
    ("diskProbe", "time of one uncached disk read, once a minute"),
    ("args", "command-line arguments in the threads capture (may hold secrets)"),
]

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Show the optional collectors, their modes and what they cost; switch them.",
        subcommands: [Show.self, Set.self, Notifications.self], defaultSubcommand: Show.self)

    struct Notifications: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Switch notifications for long slowdowns and new findings on or off.")

        enum Switch: String, ExpressibleByArgument { case on, off }
        @Argument(help: "on or off.") var state: Switch
        @Option(help: "Configuration file.") var config: String = PmonPaths.config

        func run() throws {
            let current = try Config.load(path: config).notifications
            var root = (FileManager.default.contents(atPath: config).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            var n = (root["notifications"] as? [String: Any]) ?? [:]
            n["enabled"] = state == .on
            root["notifications"] = n
            try PmonPaths.ensureSupportDir()
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: config))
            print("notifications: \(state.rawValue)")
            if state == .on {
                print("You will be told when a slowdown lasts \(Int(current.longEpisodeSeconds)) s while you are at the Mac, and about new findings;")
                print("at most one notification every \(Int(current.minGapMinutes)) minutes. macOS shows them under \"Script Editor\".")
            }
            if config == PmonPaths.config, agentLoaded() {
                let r = shell("/bin/launchctl", ["kickstart", "-k", "\(launchdDomain)/\(PmonPaths.label)"])
                print(r.status == 0 ? "daemon restarted" : "could not restart the daemon")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the optional collectors.")

        @Option(help: "Configuration file.") var config: String = PmonPaths.config
        @Option(help: "Database file.") var db: String = PmonPaths.database
        @Flag(help: "Output JSON.") var json = false

        func run() throws {
            let c = try Config.load(path: config).collectors
            let costs = measuredCosts()
            if json {
                printJSON(["collectors": collectorNotes.map { ["name": $0.name, "mode": c[$0.name]!.rawValue, "adds": $0.adds, "cost": costs[$0.name] ?? NSNull()] as [String: Any] },
                           "budget": ["maxCaptureSetsPerHour": c.maxCaptureSetsPerHour, "minBatteryPct": c.minBatteryPct, "captureCapMB": c.captureCapMB]])
                return
            }
            print("collector   mode       adds / measured cost")
            for n in collectorNotes {
                print("\(n.name.padding(toLength: 11, withPad: " ", startingAt: 0)) \(c[n.name]!.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(n.adds)")
                if let cost = costs[n.name] { print("\(String(repeating: " ", count: 23))cost: \(cost)") }
            }
            print("")
            print("Modes: off; triggered (only around a slowdown, within the budget); always.")
            print("Budget for triggered captures: one set per slowdown, \(c.maxCaptureSetsPerHour) per hour, none on battery below \(c.minBatteryPct) %.")
            print("Capture files: \(PmonPaths.captures(forDatabase: db)) (capped at \(c.captureCapMB) MB).")
            print("Change with `pmon config set <collector> <mode>`, or `pmon config set --recommended`.")
            let n = try Config.load(path: config).notifications
            print("Notifications: \(n.enabled ? "on" : "off") (`pmon config notifications on|off`).")
        }

        /// Costs observed on this machine: from past captures and scans in the database, and by
        /// timing the cheap readers right now.
        private func measuredCosts() -> [String: String] {
            var out: [String: String] = [:]
            func time(_ body: () -> Void) -> Double {
                let t0 = DispatchTime.now().uptimeNanoseconds
                for _ in 0..<5 { body() }
                return Double(DispatchTime.now().uptimeNanoseconds - t0) / 5e6
            }
            let gpu = GpuCollector()
            out["gpu"] = String(format: "%.2f ms per reading (measured now)", time { _ = gpu.utilisation() })
            out["gpuProcess"] = String(format: "%.2f ms per reading (measured now)", time { _ = gpu.clients() })
            out["network"] = "about 1.4 s of CPU per capture (nettop)"
            guard let database = try? Database(path: db, readOnly: true) else { return out }
            let kinds = ["stack": "stack", "threads": "procs", "footprint": "footprint", "network": "network"]
            for (name, kind) in kinds {
                try? database.query("SELECT COUNT(*), AVG(cost_ms), AVG(bytes) FROM capture WHERE kind = ?", [kind]) { r in
                    guard r.int(0) > 0 else { return }
                    out[name] = "\(r.int(0)) captures so far, \(Fmt.num(r.double(1) / 1000, 1)) s and \(Fmt.num(r.double(2) / 1024)) KB each on average"
                }
            }
            var scans = 0, cpu = 0.0
            try? database.query("SELECT detail FROM event WHERE kind = 'short_lived' GROUP BY ts") { r in
                guard let d = r.optText(0).flatMap({ try? JSONSerialization.jsonObject(with: Data($0.utf8)) }) as? [String: Any] else { return }
                scans += 1; cpu += (d["scan_cpu_ms"] as? NSNumber)?.doubleValue ?? 0
            }
            if scans > 0 { out["shortLived"] = "\(scans) scans so far, \(Fmt.num(cpu / Double(scans))) ms of CPU each on average" }
            try? database.query("SELECT COUNT(disk_probe_ms), AVG(disk_probe_ms) FROM sys_sample") { r in
                if r.int(0) > 0 { out["diskProbe"] = "\(r.int(0)) readings, \(Fmt.num(r.double(1), 2)) ms on average" }
            }
            return out
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Switch a collector's mode and restart the daemon.")

        @Argument(help: "Collector: \(CollectorConfig.names.joined(separator: ", ")).") var collector: String?
        @Argument(help: "Mode: off, triggered or always.") var mode: CollectorMode?
        @Flag(help: "Set stack, threads, footprint, shortLived and gpuProcess to triggered.") var recommended = false
        @Option(help: "Configuration file.") var config: String = PmonPaths.config
        @Flag(help: "Do not restart the daemon.") var noRestart = false

        func run() throws {
            var changes: [(String, CollectorMode)] = []
            if recommended {
                changes = ["stack", "threads", "footprint", "shortLived", "gpuProcess"].map { ($0, .triggered) }
            } else {
                guard let collector, let mode else { throw ValidationError("give a collector and a mode, or --recommended") }
                guard CollectorConfig.names.contains(collector) else {
                    throw ValidationError("unknown collector '\(collector)'; one of: \(CollectorConfig.names.joined(separator: ", "))")
                }
                changes = [(collector, mode)]
            }
            _ = try Config.load(path: config)        // refuse to touch a file that does not parse
            // Edit the file as a dictionary, so settings this command does not know about survive.
            var root = (FileManager.default.contents(atPath: config).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
            var collectors = (root["collectors"] as? [String: Any]) ?? [:]
            for (name, mode) in changes { collectors[name] = mode.rawValue }
            root["collectors"] = collectors
            try PmonPaths.ensureSupportDir()
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: config))
            for (name, mode) in changes { print("\(name): \(mode.rawValue)") }
            if !noRestart, config == PmonPaths.config, agentLoaded() {
                let r = shell("/bin/launchctl", ["kickstart", "-k", "\(launchdDomain)/\(PmonPaths.label)"])
                print(r.status == 0 ? "daemon restarted" : "could not restart the daemon: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                print("takes effect when the daemon next starts")
            }
        }
    }
}

extension CollectorMode: ExpressibleByArgument {}
