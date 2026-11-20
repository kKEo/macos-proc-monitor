import ArgumentParser
import Foundation
import PmonCore

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install and start the collection daemon as a per-user LaunchAgent (no root needed).")

    @Option(help: "Path to the pmond binary. Default: the one next to this pmon binary.")
    var daemon: String?

    func run() throws {
        let fm = FileManager.default
        let source = daemon ?? URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
            .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("pmond").path
        guard fm.isExecutableFile(atPath: source) else {
            throw ValidationError("pmond not found at \(source); build it or pass --daemon")
        }

        // Copy the daemon out of the build directory so rebuilding does not disturb the running one.
        try PmonPaths.ensureSupportDir()
        let target = PmonPaths.installedDaemon
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        if agentLoaded() { shell("/bin/launchctl", ["bootout", "\(launchdDomain)/\(PmonPaths.label)"]) }
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.copyItem(atPath: source, toPath: target)

        let plist: [String: Any] = [
            "Label": PmonPaths.label,
            "ProgramArguments": [target],
            "RunAtLoad": true,
            "KeepAlive": true,
            "StandardErrorPath": PmonPaths.log,
            "StandardOutPath": PmonPaths.log,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try fm.createDirectory(atPath: (PmonPaths.launchAgentPlist as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: PmonPaths.launchAgentPlist))

        // launchd can take a moment to release a label after bootout; retry briefly.
        var result = shell("/bin/launchctl", ["bootstrap", launchdDomain, PmonPaths.launchAgentPlist])
        var attempts = 0
        while result.status != 0, attempts < 5 {
            Thread.sleep(forTimeInterval: 1)
            result = shell("/bin/launchctl", ["bootstrap", launchdDomain, PmonPaths.launchAgentPlist])
            attempts += 1
        }
        guard result.status == 0 else {
            throw ValidationError("launchctl bootstrap failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        print("installed: \(target)")
        print("agent:     \(PmonPaths.launchAgentPlist)")
        print("data:      \(PmonPaths.supportDir)")
        print("The daemon is running and will start at login. Check it with `pmon status`.")
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the daemon and remove the LaunchAgent.")

    @Flag(help: "Also delete the database, logs and configuration.")
    var purge = false

    func run() throws {
        let fm = FileManager.default
        if agentLoaded() { shell("/bin/launchctl", ["bootout", "\(launchdDomain)/\(PmonPaths.label)"]) }
        try? fm.removeItem(atPath: PmonPaths.launchAgentPlist)
        try? fm.removeItem(atPath: PmonPaths.installedDaemon)
        if purge {
            try? fm.removeItem(atPath: PmonPaths.supportDir)
            print("uninstalled; data deleted")
        } else {
            print("uninstalled; data kept in \(PmonPaths.supportDir) (use --purge to delete it)")
        }
    }
}
