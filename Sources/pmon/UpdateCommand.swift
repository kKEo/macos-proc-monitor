import ArgumentParser
import Foundation
import PmonCore

struct UpdateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check GitHub for a newer pmon and install it.",
        discussion: """
            Downloads the release archive, checks its SHA-256 and the code signatures, then runs the \
            archive's own `pmon install`: binaries are replaced and the daemon and menu item restarted. \
            Your data and configuration are kept.
            """)

    @Flag(help: "Only report whether a newer version exists; change nothing.")
    var check = false

    @Option(help: "Install this version instead of the latest (also to reinstall or go back).")
    var version: String?

    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.")
    var yes = false

    @Flag(help: "Download and verify the release, but do not install it.")
    var dryRun = false

    @Flag(help: "With --check: output JSON.")
    var json = false

    @Option(help: "Configuration file.")
    var config: String = PmonPaths.config

    func run() throws {
        let settings = try Config.load(path: config).updates
        if let v = version, SemVer(v) == nil { throw ValidationError("'\(v)' is not a version such as 0.2.2") }
        try PmonPaths.ensureSupportDir()
        var state = UpdateState.load()

        let release = try Updater.fetchRelease(repository: settings.repository, version: version)
        if version == nil {
            state.latest = release
            state.checkedMs = Int64(Date().timeIntervalSince1970 * 1000)
            state.error = nil
            try? state.save()
        }
        let newer = release.isNewer()
        let setup = Installation.current

        if check {
            if json {
                printJSON(["current": PmonVersion.string, "latest": release.version, "update_available": newer,
                           "url": release.pageURL, "published": release.publishedAt ?? NSNull()])
            } else if newer {
                print("pmon \(release.version) is available (this is \(PmonVersion.string)): \(release.pageURL)")
                print("Install it with `\(setup.upgradeCommand)`.")
            } else {
                print("pmon \(PmonVersion.string) is up to date (latest release: \(release.version)).")
            }
            return
        }

        // Homebrew's files are Homebrew's to replace: anything else would leave brew's records wrong.
        if setup.isHomebrew, !dryRun {
            if newer || version != nil {
                throw Failure("pmon was installed with Homebrew; upgrade it with `\(setup.upgradeCommand)`")
            }
            print("pmon \(PmonVersion.string) is up to date (latest release: \(release.version)).")
            return
        }
        if version == nil, !newer {
            print("pmon \(PmonVersion.string) is up to date (latest release: \(release.version)).")
            return
        }
        guard let tarball = release.tarballURL, let checksum = release.checksumURL else {
            throw Failure("release \(release.tag) has no pmon-\(release.version).tar.gz with a .sha256 file; see \(release.pageURL)")
        }
        print("pmon \(PmonVersion.string) → \(release.version)  \(release.pageURL)")
        if !yes, !dryRun {
            guard isatty(STDIN_FILENO) == 1 else { throw Failure("not a terminal: pass --yes to install without asking") }
            print("Install it? The daemon and menu item restart; data and configuration are kept. [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased(), answer == "y" || answer == "yes" else {
                print("cancelled"); return
            }
        }

        do {
            try install(release, tarball: tarball, checksum: checksum)
            if dryRun { return }
            state = UpdateState.load()
            state.error = nil
            try? state.save()
        } catch {
            state = UpdateState.load()
            state.error = "installing \(release.version) failed: \(error)"
            try? state.save()
            throw error
        }
    }

    private func install(_ release: ReleaseInfo, tarball: String, checksum: String) throws {
        let fm = FileManager.default
        let setup = Installation.current
        let work = fm.temporaryDirectory.appendingPathComponent("pmon-update-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(atPath: work) }

        let archive = work + "/pmon-\(release.version).tar.gz"
        print("downloading \(tarball)")
        try Updater.download(tarball, to: archive)
        try Updater.download(checksum, to: archive + ".sha256")

        let expected = Updater.checksum(fromShasumLine: (try? String(contentsOfFile: archive + ".sha256", encoding: .utf8)) ?? "")
        guard let expected else { throw UpdateError.verification("the .sha256 file holds no SHA-256") }
        let actual = try Updater.sha256(of: archive)
        guard actual == expected else { throw UpdateError.verification("SHA-256 is \(actual), the release says \(expected)") }
        print("checksum:  ok (\(actual.prefix(16))…)")

        let unpack = shell("/usr/bin/tar", ["-xzf", archive, "-C", work])
        guard unpack.status == 0 else { throw UpdateError.verification("could not unpack: \(unpack.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        let bin = work + "/pmon-\(release.version)/bin"
        let tools = ["pmon", "pmond", "pmon-menu", "pmon-helper"]
        for t in tools where !fm.isExecutableFile(atPath: bin + "/" + t) {
            throw UpdateError.verification("the archive has no bin/\(t)")
        }

        // Every binary must carry a valid signature; when this pmon is signed by a team, the new one must be too.
        let mine = teamID(of: Bundle.main.executablePath ?? CommandLine.arguments[0])
        for t in tools {
            let path = bin + "/" + t
            let v = shell("/usr/bin/codesign", ["--verify", "--strict", path])
            guard v.status == 0 else { throw UpdateError.verification("\(t) is not validly signed: \(v.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
            if let mine, teamID(of: path) != mine {
                throw UpdateError.verification("\(t) is not signed by team \(mine), as this pmon is")
            }
        }
        print("signature: ok" + (mine.map { " (team \($0))" } ?? " (no Developer ID on this pmon to compare with)"))

        let reported = shell(bin + "/pmon", ["--version"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard reported == release.version else { throw UpdateError.verification("the new pmon reports version \(reported), not \(release.version)") }

        if dryRun { print("dry run: pmon \(release.version) downloaded and verified, not installed"); return }

        // Downloads made by this process carry no quarantine flag, so the binaries run as they are.
        print("installing")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin + "/pmon")
        p.arguments = ["install"]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.verification("`pmon install` from the new version failed (exit \(p.terminationStatus))") }
        print("pmon \(release.version) installed.")
        if fm.fileExists(atPath: HelperPaths.plist) {
            print("note: the root helper is still the old version; update it with `sudo \(setup.toolsDir)/pmon helper install`")
        }
    }

    /// The Team ID a binary is signed with, or nil for ad-hoc or unsigned code.
    private func teamID(of path: String) -> String? {
        let r = shell("/usr/bin/codesign", ["-dv", "--verbose=2", path])
        guard r.status == 0 else { return nil }
        for line in r.output.split(separator: "\n") where line.hasPrefix("TeamIdentifier=") {
            let id = String(line.dropFirst("TeamIdentifier=".count))
            return id == "not set" ? nil : id
        }
        return nil
    }
}

/// A failure reported as is, without the usage text ArgumentParser adds to validation errors.
struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
