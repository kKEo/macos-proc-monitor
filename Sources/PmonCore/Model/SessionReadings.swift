import Foundation

/// What the user's login session looks like at one tick: read on every system tick.
public struct SessionReading: Codable, Equatable, Sendable {
    /// Pid of the frontmost regular application; nil when focus is on a background agent
    /// (for example Universal Control while another Mac has the keyboard) or unknown.
    public var frontPid: Int32?
    public var frontBundleId: String?
    /// Seconds since the last keyboard or pointer input.
    public var idleSeconds: Double = 0
    public var locked = false
    public var displayOn = true
    /// 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermalLevel = 0
    public var onBattery = false
    public var lowPower = false
    public init() {}
}
