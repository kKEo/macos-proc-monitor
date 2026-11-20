import Foundation

/// Something worth telling the user about. Produced by the pipeline; whether it is shown is
/// decided by the daemon (`NoticeLimiter`).
public struct Notice: Equatable, Sendable {
    public enum Kind: String, Sendable { case longEpisode, finding }
    public var kind: Kind
    public var title: String
    public var body: String
    public init(kind: Kind, title: String, body: String) { self.kind = kind; self.title = title; self.body = body }
}

/// Notification settings. Off by default: pmon records quietly unless asked to speak up.
public struct NotifyConfig: Codable, Equatable, Sendable {
    public var enabled = false
    /// Tell me when a slowdown has lasted this long while I am at the Mac.
    public var longEpisodes = true
    public var longEpisodeSeconds = 120.0
    /// Tell me about new findings (leaks, runaway processes, a nearly full disk).
    public var findings = true
    /// Never more than one notification in this many minutes.
    public var minGapMinutes = 30.0

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        longEpisodes = try c.decodeIfPresent(Bool.self, forKey: .longEpisodes) ?? longEpisodes
        longEpisodeSeconds = try c.decodeIfPresent(Double.self, forKey: .longEpisodeSeconds) ?? longEpisodeSeconds
        findings = try c.decodeIfPresent(Bool.self, forKey: .findings) ?? findings
        minGapMinutes = try c.decodeIfPresent(Double.self, forKey: .minGapMinutes) ?? minGapMinutes
    }
}

/// Applies the switches and the rate limit. A notice that is not allowed is dropped, not queued:
/// a stale "your Mac is slow" an hour later helps nobody.
public struct NoticeLimiter: Sendable {
    public var config: NotifyConfig
    private var lastMs: Int64?

    public init(config: NotifyConfig) { self.config = config }

    public mutating func allow(_ notice: Notice, nowMs: Int64) -> Bool {
        guard config.enabled else { return false }
        switch notice.kind {
        case .longEpisode: guard config.longEpisodes else { return false }
        case .finding: guard config.findings else { return false }
        }
        if let last = lastMs, Double(nowMs - last) < config.minGapMinutes * 60_000 { return false }
        lastMs = nowMs
        return true
    }
}

/// Shows a notification through the system's scripting host: the daemon is a bare executable,
/// and the notification framework proper only works from an app bundle.
public enum Notifier {
    /// The AppleScript source for one notification, with both strings safely quoted.
    static func script(_ n: Notice) -> String {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: " ") + "\""
        }
        return "display notification \(quote(n.body)) with title \(quote(n.title))"
    }

    public static func deliver(_ n: Notice) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script(n)]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}
