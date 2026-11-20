import Foundation

/// The raw signals of one system sample that the scorer looks at.
public struct ScoreInput: Equatable, Sendable {
    /// Share of performance-core time that was busy, 0...1.
    public var pBusyShare = 0.0
    /// Foreground threads' time spent waiting for a core, as a share of all core time. Nil until
    /// the first process sweep; between sweeps the latest value is carried forward.
    public var waitShare: Double?
    public var canaryMs = 0.0
    public var pressureLevel = 1
    public var memLevelPct = 100
    /// Weighted paging activity, pages per second.
    public var thrash = 0.0
    public var queueDepth = 0.0
    public var diskFreePct: Double?
    public var thermalLevel = 0
    /// Seconds since the latest hang report, and whether it named the focused app.
    public var hangAgeSeconds: Double?
    public var hangIsFocus = false
    /// GPU device utilisation, percent. Nil when the GPU collector is off.
    public var gpuUtilPct: Double?
    public init() {}
}

/// Six sub-scores (0...100) and the sluggishness index.
public struct Scores: Equatable, Sendable {
    public var cpu = 0, mem = 0, disk = 0, thermal = 0, ui = 0
    /// Nil when the GPU collector is off.
    public var gpu: Int?

    /// The index is the *maximum* sub-score: one saturated resource makes the machine slow,
    /// however healthy the others are.
    public var index: Int { max(cpu, mem, disk, thermal, ui, gpu ?? 0) }

    public static let dimensions = ["cpu", "memory", "disk", "thermal", "gpu", "ui"]
    public func value(_ dim: String) -> Int {
        switch dim {
        case "cpu": return cpu
        case "memory": return mem
        case "disk": return disk
        case "thermal": return thermal
        case "gpu": return gpu ?? 0
        default: return ui
        }
    }
}

/// Maps raw signals to sub-scores. Stateful only in remembering the last few values of the two
/// bursty signals (paging rate, disk queue depth), which are scored on their median so that a
/// single spike does not count as pressure.
public struct Scorer: Sendable {
    public var thresholds: Thresholds
    private var thrashHistory: [Double] = []
    private var queueHistory: [Double] = []
    private var gpuHistory: [Double] = []

    public init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    public mutating func reset() { thrashHistory.removeAll(); queueHistory.removeAll(); gpuHistory.removeAll() }

    /// Linear map of `x` from [low, high] onto [0, max], clamped. Works for descending ranges too.
    static func ramp(_ x: Double, _ low: Double, _ high: Double, max: Double = 100) -> Double {
        guard low != high else { return x >= high ? max : 0 }
        return Swift.min(Swift.max((x - low) / (high - low), 0), 1) * max
    }

    private static func median3(_ history: inout [Double], _ value: Double) -> Double {
        history.append(value)
        if history.count > 3 { history.removeFirst() }
        // With fewer than three values, use the smallest: no pressure is claimed on thin evidence.
        return history.count < 3 ? history.min()! : history.sorted()[1]
    }

    public mutating func score(_ x: ScoreInput) -> Scores {
        let t = thresholds
        var s = Scores()

        let wait = x.waitShare.map { Self.ramp($0, t.waitShareLow, t.waitShareHigh) } ?? 0
        let pBusy = Self.ramp(x.pBusyShare, t.pBusyLow, t.pBusyHigh, max: t.pBusyMax)
        let canary = Self.ramp(x.canaryMs, t.canaryLowMs, t.canaryHighMs)
        s.cpu = Int(max(wait, pBusy, canary).rounded())

        let level = x.pressureLevel >= 4 ? t.pressureCriticalScore : (x.pressureLevel >= 2 ? t.pressureWarnScore : 0)
        let thrash = Self.ramp(Self.median3(&thrashHistory, x.thrash), t.thrashLow, t.thrashHigh)
        let avail = Self.ramp(Double(x.memLevelPct), t.memLevelHigh, t.memLevelLow, max: t.memLevelMax)
        s.mem = Int(max(level, thrash, avail).rounded())

        let queue = Self.ramp(Self.median3(&queueHistory, x.queueDepth), t.queueLow, t.queueHigh)
        let free = x.diskFreePct.map { Self.ramp($0, t.diskFreeHighPct, t.diskFreeLowPct, max: t.diskFreeMax) } ?? 0
        s.disk = Int(max(queue, free).rounded())

        s.thermal = Int(t.thermalScores[min(max(x.thermalLevel, 0), t.thermalScores.count - 1)].rounded())

        if let gpu = x.gpuUtilPct {
            s.gpu = Int(Self.ramp(Self.median3(&gpuHistory, gpu), t.gpuLow, t.gpuHigh).rounded())
        } else {
            gpuHistory.removeAll()
        }

        if let age = x.hangAgeSeconds, age <= t.hangSeconds {
            s.ui = x.hangIsFocus ? 100 : Int(t.uiOtherAppScore.rounded())
        }
        return s
    }
}
