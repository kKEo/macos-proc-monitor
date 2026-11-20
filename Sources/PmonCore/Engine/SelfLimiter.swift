import Foundation

/// Keeps the monitor from becoming part of the problem it measures.
///
/// Watches how long each process sweep takes and how much CPU the daemon itself uses, and
/// raises a back-off level when either stays over budget. Each level doubles the process
/// sweep interval. The level comes back down after a sustained period within budget.
public struct SelfLimiter: Sendable {
    public var sweepBudgetMs = 50.0
    /// Share of one core the daemon may use, averaged over `windowMs`.
    public var cpuBudgetShare = 0.01
    public var windowMs: Int64 = 300_000
    public var sweepsToRaise = 3
    public var sweepsToLower = 30
    public static let maxLevel = 3

    public private(set) var level = 0
    private var over = 0, under = 0
    private var window: [(dtMs: Int64, cpuMs: Int64)] = []

    public init() {}

    public var intervalMultiplier: Double { Double(1 << level) }

    /// Daemon CPU as a share of one core over the window; nil until the window has a minute of data.
    public var cpuShare: Double? {
        let dt = window.reduce(0) { $0 + $1.dtMs }
        guard dt >= 60_000 else { return nil }
        return Double(window.reduce(0) { $0 + $1.cpuMs }) / Double(dt)
    }

    /// Feed one sweep. Returns true when the level changed.
    public mutating func observe(sweepMs: Double, selfCpuMs: Int64?, dtMs: Int64) -> Bool {
        if let cpu = selfCpuMs, dtMs > 0 {
            window.append((dtMs, cpu))
            var total = window.reduce(0) { $0 + $1.dtMs }
            while window.count > 1, total - window[0].dtMs >= windowMs { total -= window[0].dtMs; window.removeFirst() }
        }
        let overBudget = sweepMs > sweepBudgetMs || (cpuShare.map { $0 > cpuBudgetShare } ?? false)
        if overBudget { over += 1; under = 0 } else { under += 1; over = 0 }
        if over >= sweepsToRaise, level < Self.maxLevel {
            level += 1; over = 0
            window.removeAll()        // judge the new cadence on its own measurements
            return true
        }
        if under >= sweepsToLower, level > 0 {
            level -= 1; under = 0
            return true
        }
        return false
    }
}
