import Foundation

/// How often to sample right now.
public struct Cadence: Equatable, Sendable {
    public var name: String
    public var systemSeconds: Double, processSeconds: Double, slowSeconds: Double
    /// Suspend the top child: nobody is looking, and it is the largest single cost.
    public var pauseTop: Bool
    /// 0 normal, 1 relaxed, 2 asleep; stored as the value of the `cadence` event.
    public var level: Int
}

/// Spend less when nobody is watching.
///
/// - Display off or screen locked: one sample a minute, top child suspended.
/// - User idle for five minutes, or on battery in Low Power Mode: a third of the normal rate.
/// - Otherwise the configured intervals.
public struct CadencePolicy: Sendable {
    public var config: Config
    public var idleSecondsForRelaxed = 300.0

    public init(config: Config) { self.config = config }

    public func decide(session: SessionReading?) -> Cadence {
        let normal = Cadence(name: "normal", systemSeconds: config.systemIntervalSeconds, processSeconds: config.processIntervalSeconds,
                             slowSeconds: config.slowIntervalSeconds, pauseTop: false, level: 0)
        guard let s = session else { return normal }
        if !s.displayOn || s.locked {
            return Cadence(name: "asleep", systemSeconds: max(60, normal.systemSeconds), processSeconds: max(60, normal.processSeconds),
                           slowSeconds: max(300, normal.slowSeconds), pauseTop: true, level: 2)
        }
        if s.idleSeconds >= idleSecondsForRelaxed || (s.onBattery && s.lowPower) {
            return Cadence(name: "relaxed", systemSeconds: normal.systemSeconds * 3, processSeconds: normal.processSeconds * 3,
                           slowSeconds: normal.slowSeconds, pauseTop: false, level: 1)
        }
        return normal
    }
}
