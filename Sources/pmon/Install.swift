import ArgumentParser
import Foundation
import PmonCore

struct Install: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install and start the collection daemon as a per-user LaunchAgent (no root needed).")

    @Option(help: "Path to the pmond binary. Default: the one next to this pmon binary.")
    var daemon: String?

    @Flag(help: "Also start the menu-bar item at login.")
    var menu = false

    func run() throws {
        // Homebrew owns its tools and starts the daemon itself; copying them out would leave a second,
        // never-upgraded daemon behind.
        if Installation.current.isHomebrew, daemon == nil {
            print("pmon was installed with Homebrew, which runs the daemon: `brew services start pmon`.")
            if menu || FileManager.default.fileExists(atPath: PmonPaths.menuAgentPlist) {
                try MenuCommand.install()
            } else {
                print("For the menu-bar item: `pmon menu install`.")
            }
            return
        }
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
        if agentLoaded(PmonPaths.label) { shell("/bin/launchctl", ["bootout", "\(launchdDomain)/\(PmonPaths.label)"]) }
        if fm.fileExists(atPath: target) { try fm.removeItem(atPath: target) }
        try fm.copyItem(atPath: source, toPath: target)
        // The other tools go along, so the build directory is not needed afterwards. Upgrading is
        // the same command again: binaries are replaced, the database is migrated when the daemon starts.
        let sourceDir = (source as NSString).deletingLastPathComponent
        for tool in ["pmon", "pmon-menu", "pmon-helper"] {
            let from = sourceDir + "/" + tool, to = PmonPaths.binDir + "/" + tool
            guard fm.isExecutableFile(atPath: from), URL(fileURLWithPath: from).resolvingSymlinksInPath().path != URL(fileURLWithPath: to).resolvingSymlinksInPath().path else { continue }
            if fm.fileExists(atPath: to) { try fm.removeItem(atPath: to) }
            try fm.copyItem(atPath: from, toPath: to)
        }

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
        if menu || fm.fileExists(atPath: PmonPaths.menuAgentPlist) { try MenuCommand.install() }
        print("tools:     \(PmonPaths.binDir) (add it to PATH, or: ln -s \"\(PmonPaths.binDir)/pmon\" /usr/local/bin/pmon)")
        print("The daemon is running and will start at login. Check it with `pmon status`.")
    }
}

struct Uninstall: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Stop the daemon and remove the LaunchAgent.")

    @Flag(help: "Also delete the database, logs and configuration.")
    var purge = false

    func run() throws {
        let fm = FileManager.default
        if agentLoaded(PmonPaths.label) { shell("/bin/launchctl", ["bootout", "\(launchdDomain)/\(PmonPaths.label)"]) }
        MenuCommand.uninstall()
        try? fm.removeItem(atPath: PmonPaths.launchAgentPlist)
        try? fm.removeItem(atPath: PmonPaths.binDir)
        if fm.fileExists(atPath: HelperPaths.plist) {
            print("note: the root helper is still installed; remove it with `sudo pmon helper uninstall` (run it before deleting this binary)")
        }
        if Installation.current.isHomebrew || agentLoaded(Installation.homebrewLabel) {
            print("note: Homebrew still runs the daemon; remove it with `brew services stop pmon && brew uninstall pmon`")
        }
        if purge {
            try? fm.removeItem(atPath: PmonPaths.supportDir)
            print("uninstalled; data deleted")
        } else {
            print("uninstalled; data kept in \(PmonPaths.supportDir) (use --purge to delete it)")
        }
    }
}

struct MenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "menu", abstract: "The menu-bar item: live index, what is busy, and a dashboard window with live charts and history.",
        subcommands: [InstallSub.self, UninstallSub.self])

    static func install() throws {
        let fm = FileManager.default
        // The stable location: our bin directory, or Homebrew's opt link, which survives upgrades.
        let setup = Installation.current
        let binary = setup.toolsDir + "/pmon-menu"
        guard fm.isExecutableFile(atPath: binary) else {
            throw ValidationError("pmon-menu not found at \(binary); " + (setup.isHomebrew ? "reinstall with `brew reinstall pmon`" : "run `pmon install` first"))
        }
        let domainTarget = "\(launchdDomain)/\(PmonPaths.menuLabel)"
        if shell("/bin/launchctl", ["print", domainTarget]).status == 0 { shell("/bin/launchctl", ["bootout", domainTarget]) }
        let plist: [String: Any] = [
            "Label": PmonPaths.menuLabel,
            "ProgramArguments": [binary],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],      // restart after a crash, not after Quit
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: PmonPaths.menuAgentPlist))
        var result = shell("/bin/launchctl", ["bootstrap", launchdDomain, PmonPaths.menuAgentPlist])
        var attempts = 0
        while result.status != 0, attempts < 5 {
            Thread.sleep(forTimeInterval: 1)
            result = shell("/bin/launchctl", ["bootstrap", launchdDomain, PmonPaths.menuAgentPlist])
            attempts += 1
        }
        guard result.status == 0 else { throw ValidationError("launchctl bootstrap failed: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        print("menu:      started; it will also start at login")
    }

    static func uninstall() {
        let domainTarget = "\(launchdDomain)/\(PmonPaths.menuLabel)"
        if shell("/bin/launchctl", ["print", domainTarget]).status == 0 { shell("/bin/launchctl", ["bootout", domainTarget]) }
        try? FileManager.default.removeItem(atPath: PmonPaths.menuAgentPlist)
    }

    struct InstallSub: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "install", abstract: "Show the menu-bar item now and at every login.")
        func run() throws { try MenuCommand.install() }
    }

    struct UninstallSub: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "uninstall", abstract: "Remove the menu-bar item.")
        func run() throws { MenuCommand.uninstall(); print("menu-bar item removed") }
    }
}
