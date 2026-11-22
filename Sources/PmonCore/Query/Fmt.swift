import Foundation

/// Shared formatting for the explanation commands and the dashboard.
public enum Fmt {
    public static func num(_ v: Double, _ digits: Int = 0) -> String { String(format: "%.\(digits)f", v) }
    public static func size(mb: Double) -> String { mb >= 1024 ? num(mb / 1024, 1) + " GB" : num(mb) + " MB" }
    public static func duration(_ ms: Int64) -> String {
        let s = Double(ms) / 1000
        if s < 90 { return num(s) + " s" }
        if s < 5400 { return num(s / 60, s < 600 ? 1 : 0) + " min" }
        return num(s / 3600, 1) + " h"
    }
    public static func clock(_ ms: Int64, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    public static func day(_ ms: Int64) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
    public static let dimensionNames = ["cpu": "CPU contention", "memory": "memory pressure", "disk": "disk I/O saturation",
                                        "thermal": "thermal throttling", "gpu": "GPU saturation", "ui": "an unresponsive app"]
}
