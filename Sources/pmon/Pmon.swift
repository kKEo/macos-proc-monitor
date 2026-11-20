import ArgumentParser
import Foundation
import PmonCore

@main
struct Pmon: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pmon",
        abstract: "Local macOS activity monitor: find what makes the machine sluggish.",
        version: PmonVersion.string,
        subcommands: [Status.self, Why.self, Episodes.self, Top.self, FindingsCommand.self, AppCommand.self, Report.self, Export.self,
                      Mark.self, ConfigCommand.self, Install.self, Uninstall.self, Replay.self, Calibrate.self])
}

/// Run a command and capture its combined output.
@discardableResult
func shell(_ launchPath: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

var launchdDomain: String { "gui/\(getuid())" }

func agentLoaded() -> Bool {
    shell("/bin/launchctl", ["print", "\(launchdDomain)/\(PmonPaths.label)"]).status == 0
}

struct Replay: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a recording through the pipeline into a database.")

    @Argument(help: "Recording file written by `pmond --record`.")
    var recording: String

    @Option(help: "Database to write. Must not be the live database.")
    var db: String

    @Option(help: "JSON file with threshold overrides (any subset of fields).")
    var thresholds: String?

    func run() throws {
        guard db != PmonPaths.database else { throw ValidationError("refusing to replay into the live database") }
        let t = try thresholds.map { try JSONDecoder().decode(Thresholds.self, from: Data(contentsOf: URL(fileURLWithPath: $0))) } ?? Thresholds()
        let n = try Replayer.replay(recording: recording, into: Database(path: db), thresholds: t)
        print("replayed \(n) ticks into \(db)")
    }
}
