import ArgumentParser
import Foundation
import PmonCore

struct HelperCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "helper",
        abstract: "The optional root helper: exact data for system-owned processes. pmon works without it.",
        discussion: """
            Without the helper, processes of other users (system daemons, WindowServer) are measured \
            through `top` every 30 seconds, and their disk activity is only known as a combined total. \
            With it, they are read like your own processes: same interval, per-process disk, energy \
            and wait time, and stack captures of system processes become possible.

            The helper runs as root, holds no state, writes no files and accepts requests only from \
            your user's installed pmond. Installing needs sudo; uninstalling removes everything it added:
              \(HelperPaths.binary)
              \(HelperPaths.plist)
            """,
        subcommands: [StatusSub.self, InstallSub.self, UninstallSub.self], defaultSubcommand: StatusSub.self)

    struct StatusSub: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show whether the helper is installed and answering.")
        func run() throws {
            print("root helper: \(helperSummary())")
            if !FileManager.default.fileExists(atPath: HelperPaths.plist) { print("Install with: sudo \(CommandLine.arguments[0]) helper install") }
        }
    }

    struct InstallSub: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Install the helper as a LaunchDaemon (run with sudo).")

        @Option(help: "Path to the pmon-helper binary. Default: the one next to this pmon binary.")
        var binary: String?

        @Option(help: "User the helper serves. Default: the user who ran sudo.")
        var user: String?

        func run() throws {
            guard geteuid() == 0 else { throw ValidationError("needs root: run `sudo \(CommandLine.arguments[0]) helper install`") }
            guard let name = user ?? ProcessInfo.processInfo.environment["SUDO_USER"], let pw = getpwnam(name), pw.pointee.pw_uid != 0 else {
                throw ValidationError("cannot tell which user to serve; pass --user <name>")
            }
            let uid = pw.pointee.pw_uid
            let home = String(cString: pw.pointee.pw_dir)
            let client = home + "/Library/Application Support/pmon/bin/pmond"
            let fm = FileManager.default
            let source = binary ?? URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
                .resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("pmon-helper").path
            guard fm.isExecutableFile(atPath: source) else { throw ValidationError("pmon-helper not found at \(source); build it or pass --binary") }
            guard fm.isExecutableFile(atPath: client) else { throw ValidationError("the daemon is not installed for \(name); run `pmon install` (without sudo) first") }

            let system = "system/\(HelperPaths.label)"
            shell("/bin/launchctl", ["bootout", system])
            try fm.createDirectory(atPath: (HelperPaths.binary as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if fm.fileExists(atPath: HelperPaths.binary) { try fm.removeItem(atPath: HelperPaths.binary) }
            try fm.copyItem(atPath: source, toPath: HelperPaths.binary)
            // Root-owned and not writable by anyone else: the copy in the build directory no longer matters.
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o755], ofItemAtPath: HelperPaths.binary)
            let plist: [String: Any] = [
                "Label": HelperPaths.label,
                "ProgramArguments": [HelperPaths.binary, "--uid", "\(uid)", "--client", client],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ProcessType": "Background",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: HelperPaths.plist))
            try fm.setAttributes([.ownerAccountID: 0, .groupOwnerAccountID: 0, .posixPermissions: 0o644], ofItemAtPath: HelperPaths.plist)
            let r = shell("/bin/launchctl", ["bootstrap", "system", HelperPaths.plist])
            guard r.status == 0 else { throw ValidationError("launchctl bootstrap failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            print("installed: \(HelperPaths.binary)")
            print("agent:     \(HelperPaths.plist)")
            print("serving:   \(name) (uid \(uid)), client \(client)")
            print("The daemon picks the helper up within a minute; `pmon status` shows it.")
        }
    }

    struct UninstallSub: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Stop and remove the helper (run with sudo).")
        func run() throws {
            guard geteuid() == 0 else { throw ValidationError("needs root: run `sudo \(CommandLine.arguments[0]) helper uninstall`") }
            shell("/bin/launchctl", ["bootout", "system/\(HelperPaths.label)"])
            for path in [HelperPaths.plist, HelperPaths.binary, HelperPaths.socket] { try? FileManager.default.removeItem(atPath: path) }
            print("helper removed; pmon carries on without it")
        }
    }
}
