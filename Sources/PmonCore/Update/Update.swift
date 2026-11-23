import Foundation
import CryptoKit

// Update checks against the project's GitHub releases. The only network traffic pmon makes:
// one HTTPS request to api.github.com per check, and the downloads of `pmon update`.

/// A semantic version such as 0.2.2 or 0.3.0-rc.1, ordered as semver orders them.
public struct SemVer: Comparable, CustomStringConvertible, Sendable {
    public var major: Int, minor: Int, patch: Int
    /// Dot-separated pre-release identifiers; empty for a release.
    public var pre: [String]

    public init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.hasPrefix("v") { s = s.dropFirst() }
        let dash = s.firstIndex(of: "-")
        let core = dash.map { s[..<$0] } ?? s
        let nums = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard nums.count == 3, let a = nums[0], let b = nums[1], let c = nums[2], a >= 0, b >= 0, c >= 0 else { return nil }
        (major, minor, patch) = (a, b, c)
        pre = dash.map { s[s.index(after: $0)...].split(separator: ".", omittingEmptySubsequences: false).map(String.init) } ?? []
        guard !pre.contains(where: \.isEmpty) else { return nil }
    }

    public var isPrerelease: Bool { !pre.isEmpty }
    public var description: String { "\(major).\(minor).\(patch)" + (pre.isEmpty ? "" : "-" + pre.joined(separator: ".")) }

    public static func < (l: SemVer, r: SemVer) -> Bool {
        if (l.major, l.minor, l.patch) != (r.major, r.minor, r.patch) { return (l.major, l.minor, l.patch) < (r.major, r.minor, r.patch) }
        // A release sorts after its pre-releases.
        if l.pre.isEmpty || r.pre.isEmpty { return !l.pre.isEmpty && r.pre.isEmpty }
        for (a, b) in zip(l.pre, r.pre) where a != b {
            switch (Int(a), Int(b)) {
            case let (x?, y?): return x < y
            case (.some, nil): return true            // numeric identifiers sort before alphanumeric ones
            case (nil, .some): return false
            case (nil, nil): return a < b
            }
        }
        return l.pre.count < r.pre.count
    }

    public static func == (l: SemVer, r: SemVer) -> Bool { !(l < r) && !(r < l) }
}

/// Update check settings. On by default: the daemon asks GitHub once a day whether a newer release exists.
public struct UpdateConfig: Codable, Equatable, Sendable {
    /// Let the daemon check by itself. `pmon update` works either way.
    public var autoCheck = true
    public var checkIntervalHours = 24.0
    /// Show a notification once per new version (independent of the slowdown notifications).
    public var notify = true
    /// GitHub repository the releases come from, as owner/name.
    public var repository = "kKEo/macos-proc-monitor"

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoCheck = try c.decodeIfPresent(Bool.self, forKey: .autoCheck) ?? autoCheck
        checkIntervalHours = try c.decodeIfPresent(Double.self, forKey: .checkIntervalHours) ?? checkIntervalHours
        notify = try c.decodeIfPresent(Bool.self, forKey: .notify) ?? notify
        repository = try c.decodeIfPresent(String.self, forKey: .repository) ?? repository
    }
}

/// One published release and the files `pmon update` needs from it.
public struct ReleaseInfo: Codable, Equatable, Sendable {
    public var version: String
    public var tag: String
    public var pageURL: String
    public var publishedAt: String?
    public var tarballURL: String?
    public var checksumURL: String?

    public init(version: String, tag: String, pageURL: String, publishedAt: String? = nil, tarballURL: String? = nil, checksumURL: String? = nil) {
        self.version = version; self.tag = tag; self.pageURL = pageURL
        self.publishedAt = publishedAt; self.tarballURL = tarballURL; self.checksumURL = checksumURL
    }

    /// Parse one release object of the GitHub REST API. Drafts and tags that are not versions give nil.
    public static func parse(github data: Data) throws -> ReleaseInfo? {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateError.badResponse("not a JSON object") }
        guard let tag = o["tag_name"] as? String else {
            throw UpdateError.badResponse((o["message"] as? String) ?? "no tag_name in the response")
        }
        guard (o["draft"] as? Bool) != true, let v = SemVer(tag) else { return nil }
        let version = v.description
        var assets: [String: String] = [:]
        for a in (o["assets"] as? [[String: Any]]) ?? [] {
            if let name = a["name"] as? String, let url = a["browser_download_url"] as? String { assets[name] = url }
        }
        return ReleaseInfo(version: version, tag: tag, pageURL: (o["html_url"] as? String) ?? "",
                           publishedAt: o["published_at"] as? String,
                           tarballURL: assets["pmon-\(version).tar.gz"], checksumURL: assets["pmon-\(version).tar.gz.sha256"])
    }

    /// Whether this release is newer than the running pmon.
    public func isNewer(than current: String = PmonVersion.string) -> Bool {
        guard let mine = SemVer(current), let theirs = SemVer(version) else { return false }
        return theirs > mine
    }
}

public enum UpdateError: Error, CustomStringConvertible {
    case network(String)
    case badResponse(String)
    case notFound(String)
    case verification(String)

    public var description: String {
        switch self {
        case .network(let m): return "could not reach GitHub: \(m)"
        case .badResponse(let m): return "unexpected answer from GitHub: \(m)"
        case .notFound(let m): return m
        case .verification(let m): return "verification failed: \(m)"
        }
    }
}

/// What the last check found, kept in update.json so the menu and `pmon status` can show it without asking GitHub.
public struct UpdateState: Codable, Equatable, Sendable {
    /// When GitHub was last asked successfully (ms since 1970).
    public var checkedMs: Int64?
    public var latest: ReleaseInfo?
    /// The last failed check or install, cleared by the next success.
    public var error: String?
    /// The version already announced in a notification, so each version is announced once.
    public var notifiedVersion: String?

    public init() {}

    public static var path: String { PmonPaths.supportDir + "/update.json" }

    public static func load(path: String = UpdateState.path) -> UpdateState {
        guard let data = FileManager.default.contents(atPath: path) else { return UpdateState() }
        return (try? JSONDecoder().decode(UpdateState.self, from: data)) ?? UpdateState()
    }

    public func save(path: String = UpdateState.path) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// The newer release recorded by the last check, if any.
    public func available(current: String = PmonVersion.string) -> ReleaseInfo? {
        latest.flatMap { $0.isNewer(than: current) ? $0 : nil }
    }

    public func isDue(intervalHours: Double, nowMs: Int64) -> Bool {
        guard let last = checkedMs else { return true }
        return Double(nowMs - last) >= intervalHours * 3_600_000 || nowMs < last
    }
}

public enum Updater {
    /// The latest stable release (GitHub's "latest" never points at a pre-release), or the one tagged `version`.
    public static func fetchRelease(repository: String, version: String? = nil, timeout: TimeInterval = 20) throws -> ReleaseInfo {
        let path = version.map { "releases/tags/v\(SemVer($0)?.description ?? $0)" } ?? "releases/latest"
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/\(path)") else {
            throw UpdateError.badResponse("bad repository name \(repository)")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("pmon/\(PmonVersion.string)", forHTTPHeaderField: "User-Agent")
        let (data, status) = try get(req)
        if status == 404 { throw UpdateError.notFound(version.map { "no release \($0) in \(repository)" } ?? "\(repository) has no releases yet") }
        guard status == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw UpdateError.badResponse("HTTP \(status)" + (message.map { ": \($0)" } ?? ""))
        }
        guard let release = try ReleaseInfo.parse(github: data) else { throw UpdateError.notFound("the latest release is not a pmon version") }
        return release
    }

    /// Download `url` to `destination`.
    public static func download(_ url: String, to destination: String, timeout: TimeInterval = 300) throws {
        guard let u = URL(string: url) else { throw UpdateError.badResponse("bad URL \(url)") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.setValue("pmon/\(PmonVersion.string)", forHTTPHeaderField: "User-Agent")
        let (data, status) = try get(req)
        guard status == 200 else { throw UpdateError.network("HTTP \(status) for \(url)") }
        try data.write(to: URL(fileURLWithPath: destination))
    }

    /// The SHA-256 of a file as lowercase hex.
    public static func sha256(of path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The hash in a `shasum -a 256` line ("<hex>  <file>").
    public static func checksum(fromShasumLine text: String) -> String? {
        guard let first = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let hex = first.lowercased()
        return hex.count == 64 && hex.allSatisfy(\.isHexDigit) ? hex : nil
    }

    /// Ask GitHub when a check is due and record the outcome. Returns the release to announce, if a
    /// newer one was found and not announced before. Used by the daemon; blocks for up to `timeout`.
    public static func scheduledCheck(config: UpdateConfig, statePath: String = UpdateState.path,
                                      nowMs: Int64 = Int64(Date().timeIntervalSince1970 * 1000)) -> ReleaseInfo? {
        guard config.autoCheck else { return nil }
        var state = UpdateState.load(path: statePath)
        guard state.isDue(intervalHours: max(config.checkIntervalHours, 1), nowMs: nowMs) else { return nil }
        do {
            state.latest = try fetchRelease(repository: config.repository)
            state.checkedMs = nowMs
            state.error = nil
        } catch {
            // A failed check is retried at the next interval, not hammered: count it as a check.
            state.checkedMs = nowMs
            state.error = "\(error)"
            Log.error("update check: \(error)")
        }
        var announce: ReleaseInfo?
        if let r = state.available(), state.notifiedVersion != r.version {
            Log.info("update available: pmon \(r.version) (running \(PmonVersion.string))")
            if config.notify { announce = r }
            state.notifiedVersion = r.version
        }
        try? state.save(path: statePath)
        return announce
    }

    private final class Box: @unchecked Sendable { var result: Result<(Data, Int), Error>? }

    /// A blocking GET; the CLI and the daemon's check queue are both fine to block.
    private static func get(_ req: URLRequest) throws -> (Data, Int) {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: req) { data, response, error in
            if let error {
                box.result = .failure(UpdateError.network(error.localizedDescription))
            } else {
                box.result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        return try box.result!.get()
    }
}
