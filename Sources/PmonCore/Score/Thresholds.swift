import Foundation

/// Every tunable number of the sluggishness model, in one place.
///
/// Each sub-score maps a raw signal linearly from "no problem" (0) to "saturated" (100)
/// between a low and a high threshold. Starting values come from phase 0 measurements and
/// from the idle baseline of the development machine; calibration adjusts them.
public struct Thresholds: Codable, Equatable, Sendable {
    // CPU. Wait share = time foreground threads spent ready but without a core, as a share of
    // total core time. 16 busy threads on 8 cores give 1.0.
    public var waitShareLow = 0.05, waitShareHigh = 0.75
    /// Performance cores busy but nothing waiting is only a mild signal: capped at `pBusyMax`.
    public var pBusyLow = 0.85, pBusyHigh = 1.0, pBusyMax = 50.0
    /// Lateness of the daemon's own strict timer (idle: about 0.2 ms; one-off spikes to 60 ms were seen).
    public var canaryLowMs = 10.0, canaryHighMs = 150.0

    // Memory. The kernel's pressure level is sticky, so on its own it contributes little.
    public var pressureWarnScore = 25.0, pressureCriticalScore = 75.0
    /// Paging activity in pages per second: decompressions + page-ins + 4 x (swap-ins + swap-outs),
    /// median of the last three samples. Idle baseline: median 90, 95th percentile 3000.
    public var thrashLow = 4000.0, thrashHigh = 30000.0
    /// `memorystatus_level` (percent of memory still available): 0 at `memLevelHigh`, `memLevelMax` at `memLevelLow`.
    public var memLevelHigh = 30.0, memLevelLow = 8.0, memLevelMax = 60.0

    // Disk. Queue depth = summed request latency / interval, median of the last three samples.
    public var queueLow = 0.5, queueHigh = 3.0
    /// A nearly full volume is a standing condition, not an episode: it adds at most `diskFreeMax`.
    public var diskFreeHighPct = 10.0, diskFreeLowPct = 2.0, diskFreeMax = 30.0

    /// Score per thermal level: nominal, fair, serious, critical.
    public var thermalScores = [0.0, 20.0, 70.0, 100.0]

    /// A hang report for the focused app scores 100 for this long; for another app, `uiOtherAppScore`.
    public var hangSeconds = 30.0, uiOtherAppScore = 50.0

    // Episodes.
    public var openAt = 60, closeAt = 40
    /// Open when at least `openNeeded` of the last `openWindow` samples are at or above `openAt`.
    public var openNeeded = 3, openWindow = 5
    /// Close once the index has stayed below `closeAt` for this long. Also merges flapping.
    public var calmSeconds = 45.0
    /// The user counts as present when input is more recent than this, the display is on and the screen unlocked.
    public var presentIdleSeconds = 120.0

    // Blame.
    public var qosWeightUtility = 0.5, qosWeightBackground = 0.2
    public var memoryHoldWeight = 0.6, memoryGrowthWeight = 0.4
    public var memoryLeadSeconds = 600.0, thermalLeadSeconds = 300.0
    /// Shares below this are not stored.
    public var minShare = 0.02
    /// A dimension must average at least this score over the episode to be blamed at all. Above the
    /// standing contribution of a nearly full disk (about 20-25), which is not anyone's fault.
    public var minDimensionScore = 30.0

    public init() {}

    public init(from decoder: Decoder) throws {
        // Any subset of fields may be given; the rest keep their defaults.
        self.init()
        let c = try decoder.container(keyedBy: AnyKey.self)
        var mirror = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Thresholds())) as! [String: Any]
        for key in c.allKeys {
            guard mirror[key.stringValue] != nil else { continue }
            if let v = try? c.decode(Double.self, forKey: key) { mirror[key.stringValue] = v }
            else if let v = try? c.decode([Double].self, forKey: key) { mirror[key.stringValue] = v }
        }
        self = try JSONDecoder().decode(Plain.self, from: JSONSerialization.data(withJSONObject: mirror)).value
    }

    private struct AnyKey: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Decodes a complete set of fields with the synthesized decoder.
    private struct Plain: Decodable {
        var value = Thresholds()
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func d(_ k: CodingKeys) throws -> Double { try c.decode(Double.self, forKey: k) }
            func i(_ k: CodingKeys) throws -> Int { Int(try c.decode(Double.self, forKey: k)) }
            value.waitShareLow = try d(.waitShareLow); value.waitShareHigh = try d(.waitShareHigh)
            value.pBusyLow = try d(.pBusyLow); value.pBusyHigh = try d(.pBusyHigh); value.pBusyMax = try d(.pBusyMax)
            value.canaryLowMs = try d(.canaryLowMs); value.canaryHighMs = try d(.canaryHighMs)
            value.pressureWarnScore = try d(.pressureWarnScore); value.pressureCriticalScore = try d(.pressureCriticalScore)
            value.thrashLow = try d(.thrashLow); value.thrashHigh = try d(.thrashHigh)
            value.memLevelHigh = try d(.memLevelHigh); value.memLevelLow = try d(.memLevelLow); value.memLevelMax = try d(.memLevelMax)
            value.queueLow = try d(.queueLow); value.queueHigh = try d(.queueHigh)
            value.diskFreeHighPct = try d(.diskFreeHighPct); value.diskFreeLowPct = try d(.diskFreeLowPct); value.diskFreeMax = try d(.diskFreeMax)
            value.thermalScores = try c.decode([Double].self, forKey: .thermalScores)
            value.hangSeconds = try d(.hangSeconds); value.uiOtherAppScore = try d(.uiOtherAppScore)
            value.openAt = try i(.openAt); value.closeAt = try i(.closeAt)
            value.openNeeded = try i(.openNeeded); value.openWindow = try i(.openWindow)
            value.calmSeconds = try d(.calmSeconds); value.presentIdleSeconds = try d(.presentIdleSeconds)
            value.qosWeightUtility = try d(.qosWeightUtility); value.qosWeightBackground = try d(.qosWeightBackground)
            value.memoryHoldWeight = try d(.memoryHoldWeight); value.memoryGrowthWeight = try d(.memoryGrowthWeight)
            value.memoryLeadSeconds = try d(.memoryLeadSeconds); value.thermalLeadSeconds = try d(.thermalLeadSeconds)
            value.minShare = try d(.minShare); value.minDimensionScore = try d(.minDimensionScore)
        }
    }

    enum CodingKeys: String, CodingKey {
        case waitShareLow, waitShareHigh, pBusyLow, pBusyHigh, pBusyMax, canaryLowMs, canaryHighMs
        case pressureWarnScore, pressureCriticalScore, thrashLow, thrashHigh, memLevelHigh, memLevelLow, memLevelMax
        case queueLow, queueHigh, diskFreeHighPct, diskFreeLowPct, diskFreeMax, thermalScores, hangSeconds, uiOtherAppScore
        case openAt, closeAt, openNeeded, openWindow, calmSeconds, presentIdleSeconds
        case qosWeightUtility, qosWeightBackground, memoryHoldWeight, memoryGrowthWeight, memoryLeadSeconds, thermalLeadSeconds
        case minShare, minDimensionScore
    }
}
