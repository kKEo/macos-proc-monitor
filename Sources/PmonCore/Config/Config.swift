import Foundation

public enum PmonVersion {
    public static let string = "0.1.0"
}

/// Well-known locations. Everything lives in the user's home directory; nothing needs root.
public enum PmonPaths {
    public static let label = "dev.pmon.daemon"

    public static var supportDir: String {
        NSHomeDirectory() + "/Library/Application Support/pmon"
    }
    public static var database: String { supportDir + "/pmon.db" }
    public static var config: String { supportDir + "/config.json" }
    public static var lock: String { lock(forDatabase: database) }
    /// The single-instance lock sits next to the database it protects.
    public static func lock(forDatabase db: String) -> String { db + ".lock" }
    public static var log: String { supportDir + "/pmond.log" }
    public static var installedDaemon: String { supportDir + "/bin/pmond" }
    public static var launchAgentPlist: String { NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist" }

    /// Create the support directory, readable by the owner only.
    public static func ensureSupportDir() throws {
        try FileManager.default.createDirectory(atPath: supportDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
}

/// User-tunable settings. Every field has a default, so a missing or partial file is fine.
public struct Config: Codable, Equatable, Sendable {
    public var systemIntervalSeconds: Double = 5
    public var processIntervalSeconds: Double = 10
    public var slowIntervalSeconds: Double = 60
    public var recordingCapMB: Int = 256
    /// Interval of the `top` stream that covers other users' processes.
    public var foreignIntervalSeconds: Double = 30
    /// Set false to cover other users' processes with `ps` only.
    public var topStreamEnabled = true
    /// Sample less often when the user is away, the display is off, or in Low Power Mode on battery.
    public var relaxWhenIdle = true
    /// Tunable numbers of the sluggishness model; any subset may be given.
    public var thresholds = Thresholds()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        systemIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .systemIntervalSeconds) ?? d.systemIntervalSeconds
        processIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .processIntervalSeconds) ?? d.processIntervalSeconds
        slowIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .slowIntervalSeconds) ?? d.slowIntervalSeconds
        recordingCapMB = try c.decodeIfPresent(Int.self, forKey: .recordingCapMB) ?? d.recordingCapMB
        foreignIntervalSeconds = try c.decodeIfPresent(Double.self, forKey: .foreignIntervalSeconds) ?? d.foreignIntervalSeconds
        topStreamEnabled = try c.decodeIfPresent(Bool.self, forKey: .topStreamEnabled) ?? d.topStreamEnabled
        relaxWhenIdle = try c.decodeIfPresent(Bool.self, forKey: .relaxWhenIdle) ?? d.relaxWhenIdle
        thresholds = try c.decodeIfPresent(Thresholds.self, forKey: .thresholds) ?? d.thresholds
    }

    /// Load from `path`; a missing file yields the defaults, a malformed one is an error.
    public static func load(path: String = PmonPaths.config) throws -> Config {
        guard let data = FileManager.default.contents(atPath: path) else { return Config() }
        return try JSONDecoder().decode(Config.self, from: data)
    }
}

/// Minimal timestamped logging to stderr (launchd redirects it to the log file).
public enum Log {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let lock = NSLock()

    public static func info(_ message: String) { write("INFO", message) }
    public static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        FileHandle.standardError.write(Data("\(formatter.string(from: Date())) \(level) \(message)\n".utf8))
    }
}
