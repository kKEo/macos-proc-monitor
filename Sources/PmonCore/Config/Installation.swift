import Foundation

/// How this copy of pmon was installed, which decides who starts the daemon and who upgrades it.
///  - `pmon install` (or a release's install.sh): tools copied to the support directory, LaunchAgent `dev.pmon.daemon`.
///  - Homebrew: tools under `<prefix>/Cellar/pmon/<version>`, the daemon run by `brew services` (`homebrew.mxcl.pmon`).
public enum Installation: Equatable, Sendable {
    case standalone
    case homebrew(prefix: String)

    /// The LaunchAgent label `brew services` gives the formula's service.
    public static let homebrewLabel = "homebrew.mxcl.pmon"

    /// Decide from an executable's real path (symlinks resolved): Homebrew keeps formulas in `<prefix>/Cellar/<name>/<version>/`.
    public static func detect(executable path: String) -> Installation {
        let parts = URL(fileURLWithPath: path).resolvingSymlinksInPath().pathComponents
        if let i = parts.firstIndex(of: "Cellar"), i + 2 < parts.count, parts[i + 1] == "pmon" {
            return .homebrew(prefix: NSString.path(withComponents: Array(parts[..<i])))
        }
        return .standalone
    }

    /// The installation of the running program.
    public static var current: Installation {
        detect(executable: Bundle.main.executablePath ?? CommandLine.arguments[0])
    }

    public var isHomebrew: Bool { if case .homebrew = self { return true } else { return false } }

    /// Where the tools stay put across upgrades. For Homebrew that is the `opt` link, not the versioned
    /// Cellar directory, which `brew upgrade` removes.
    public var toolsDir: String {
        switch self {
        case .standalone: return PmonPaths.binDir
        case .homebrew(let prefix): return prefix + "/opt/pmon/bin"
        }
    }

    /// What to run to install a newer release.
    public var upgradeCommand: String {
        isHomebrew ? "brew update && brew upgrade pmon" : "pmon update"
    }

    /// The label of the LaunchAgent that runs the daemon for this installation.
    public var daemonLabel: String { isHomebrew ? Installation.homebrewLabel : PmonPaths.label }
}
