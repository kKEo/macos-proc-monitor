import Foundation

/// The application a process is attributed to.
public struct AppRef: Equatable, Sendable {
    /// Stable key: bundle identifier, or the executable path when there is no bundle.
    public var key: String
    public var name: String
    /// `app` (a bundle the user can quit), `system` (part of the OS), `daemon`, or `cli`.
    public var kind: String
    public var bundlePath: String?
    /// Children of a process attributed to a bundle inherit that bundle (a build run from a terminal
    /// belongs to the terminal). Children of a bare executable do not inherit it.
    var inheritable: Bool
}

/// Which rule attributed a process to its app; stored in `process.attribution`.
public enum AttributionRule: String, Sendable {
    case responsible, bundle, coalition, parent, exe
}

/// Maps processes to applications, so reports say "Chrome", not "Helper (Renderer) pid 4312".
///
/// Rules, first match wins:
/// 1. `responsible` — the app macOS holds responsible for the process (what Activity Monitor
///    groups by). Only known for processes we can read natively.
/// 2. `bundle` — the outermost `.app` bundle containing the executable.
/// 3. `coalition` — another process in the same launchd coalition already belongs to a bundle.
/// 4. `parent` — the parent process belongs to a bundle.
/// 5. `exe` — the executable is its own app.
///
/// Pure: works only from the identities it is given, so a replay attributes identically.
public struct AppResolver {
    private var resolved: [UInt64: AppRef] = [:]          // live processes by unique id
    private var uidByPid: [Int32: UInt64] = [:]
    private var coalitionApp: [UInt64: AppRef] = [:]

    public init() {}

    public static let systemPathPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/"]

    /// Resolve a batch of newly seen processes. Parents and responsible processes may be in the
    /// same batch, in any order.
    public mutating func resolve(_ batch: [ProcIdentity]) -> [UInt64: (app: AppRef, rule: AttributionRule)] {
        let byUid = Dictionary(batch.map { ($0.uid, $0) }, uniquingKeysWith: { a, _ in a })
        for id in batch { uidByPid[id.pid] = id.uid }

        // Coalitions are claimed by the first bundle process seen in them. Coalition 1 holds the
        // system's own daemons and is never used for attribution.
        for id in batch where id.bundlePath != nil {
            if let c = id.coalitionId, c > 1, coalitionApp[c] == nil { coalitionApp[c] = Self.bundleApp(id) }
        }

        var memo: [UInt64: (AppRef, AttributionRule)] = [:]
        var visiting = Set<UInt64>()

        func known(_ uid: UInt64) -> AppRef? {
            if let id = byUid[uid] { return go(id).0 }
            return resolved[uid]
        }

        func go(_ id: ProcIdentity) -> (AppRef, AttributionRule) {
            if let m = memo[id.uid] { return m }
            guard visiting.insert(id.uid).inserted else { return (Self.exeApp(id), .exe) }   // cycle guard
            defer { visiting.remove(id.uid) }
            var result: (AppRef, AttributionRule)
            if let rp = id.responsiblePid, rp != id.pid, let ruid = uidByPid[rp], ruid != id.uid, let app = known(ruid) {
                result = (app, .responsible)
            } else if id.bundlePath != nil {
                result = (Self.bundleApp(id), .bundle)
            } else if let c = id.coalitionId, c > 1, let app = coalitionApp[c] {
                result = (app, .coalition)
            } else if id.parentUid != id.uid, let parent = known(id.parentUid), parent.inheritable {
                result = (parent, .parent)
            } else {
                result = (Self.exeApp(id), .exe)
            }
            memo[id.uid] = result
            return result
        }

        var out: [UInt64: (app: AppRef, rule: AttributionRule)] = [:]
        for id in batch {
            let r = go(id)
            out[id.uid] = (r.0, r.1)
            resolved[id.uid] = r.0
        }
        return out
    }

    /// Forget processes that have exited.
    public mutating func retain(present: Set<UInt64>) {
        guard resolved.count > present.count + 256 else { return }
        resolved = resolved.filter { present.contains($0.key) }
        uidByPid = uidByPid.filter { present.contains($0.value) }
    }

    static func bundleApp(_ id: ProcIdentity) -> AppRef {
        let path = id.bundlePath!
        let fallbackName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // Bundles inside /System/Library are parts of the OS (Dock, WindowManager, ...), not apps the
        // user chose to run; /System/Applications holds real apps such as Mail.
        let kind = ["/System/Library/", "/Library/Apple/", "/usr/"].contains { path.hasPrefix($0) } ? "system" : "app"
        return AppRef(key: id.bundleId ?? path, name: id.bundleName ?? fallbackName, kind: kind, bundlePath: path, inheritable: true)
    }

    static func exeApp(_ id: ProcIdentity) -> AppRef {
        let kind: String
        if id.pid == 0 || systemPathPrefixes.contains(where: { id.path.hasPrefix($0) }) {
            kind = "system"
        } else if id.ppid <= 1 {
            kind = "daemon"
        } else {
            kind = "cli"
        }
        let name = id.name.isEmpty ? (id.path as NSString).lastPathComponent : id.name
        return AppRef(key: id.path, name: name, kind: kind, bundlePath: nil, inheritable: false)
    }
}
