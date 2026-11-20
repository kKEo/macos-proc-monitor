import Foundation

/// Turns the index series into episodes: sustained periods where the machine is bottlenecked.
///
/// - Opens when at least `openNeeded` of the last `openWindow` samples reach `openAt`.
/// - Closes once the index has stayed below `closeAt` for `calmSeconds`. The episode then ends
///   at the last sample that was still at or above `closeAt`, not at the end of the calm period.
/// - Because closing needs sustained calm, a signal that flaps yields one episode, not many.
public struct EpisodeDetector: Sendable {
    public enum Transition: Equatable, Sendable {
        /// An episode began at `startTs` (the first qualifying sample of the opening window).
        case opened(startTs: Int64)
        /// The open episode ended at `endTs`.
        case closed(endTs: Int64)
    }

    public var thresholds: Thresholds
    private var recent: [(ts: Int64, index: Int)] = []
    public private(set) var isOpen = false
    /// Last sample at or above `closeAt` while open.
    public private(set) var lastActiveTs: Int64 = 0

    public init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    /// Whether sampling should run at the fast cadence: an episode is open, or one may be forming.
    public var wantsFastCadence: Bool {
        isOpen || (recent.last.map { $0.index >= thresholds.closeAt } ?? false)
    }

    public mutating func observe(ts: Int64, index: Int) -> Transition? {
        recent.append((ts, index))
        if recent.count > thresholds.openWindow { recent.removeFirst() }

        if isOpen {
            if index >= thresholds.closeAt {
                lastActiveTs = ts
            } else if Double(ts - lastActiveTs) >= thresholds.calmSeconds * 1000 {
                isOpen = false
                recent.removeAll()
                return .closed(endTs: lastActiveTs)
            }
            return nil
        }
        let hot = recent.filter { $0.index >= thresholds.openAt }
        if hot.count >= thresholds.openNeeded {
            isOpen = true
            lastActiveTs = ts
            return .opened(startTs: hot.first!.ts)
        }
        return nil
    }

    /// End the open episode now (sleep, shutdown). Returns its end time, if one was open.
    public mutating func forceClose() -> Int64? {
        recent.removeAll()
        guard isOpen else { return nil }
        isOpen = false
        return lastActiveTs
    }
}

/// Running summary of the open episode, weighted by the time each sample covers.
struct EpisodeSummary {
    var id: Int64 = 0
    var startTs: Int64 = 0
    private var weight = 0.0
    private var sums = [String: Double]()
    private var indexSum = 0.0
    private(set) var peak = 0
    private var presentWeight = 0.0
    private var focus: [Int64: Double] = [:]
    private(set) var onBattery = false, lowPower = false

    // Samples since the last one at or above the close threshold: discarded if the episode
    // closes, folded in if activity resumes.
    private var tail: [(dt: Double, scores: Scores, present: Bool, focus: Int64?)] = []

    mutating func add(dtMs: Int64, scores: Scores, present: Bool, focus focusApp: Int64?, session: SessionReading?, active: Bool) {
        let entry = (Double(max(dtMs, 1)), scores, present, focusApp)
        if let s = session { onBattery = onBattery || s.onBattery; lowPower = lowPower || s.lowPower }
        guard active else { tail.append(entry); return }
        for e in tail + [entry] {
            weight += e.0
            indexSum += Double(e.1.index) * e.0
            for dim in Scores.dimensions { sums[dim, default: 0] += Double(e.1.value(dim)) * e.0 }
            peak = max(peak, e.1.index)
            if e.2 { presentWeight += e.0 }
            if let f = e.3 { focus[f, default: 0] += e.0 }
        }
        tail.removeAll()
    }

    var meanIndex: Int { weight > 0 ? Int((indexSum / weight).rounded()) : 0 }
    func mean(_ dim: String) -> Double { weight > 0 ? (sums[dim] ?? 0) / weight : 0 }
    var dominant: String { Scores.dimensions.max { mean($0) < mean($1) } ?? "cpu" }
    var userPresent: Bool { weight > 0 && presentWeight / weight >= 0.5 }
    var focusApp: Int64? { focus.max { $0.value < $1.value }?.key }
}
