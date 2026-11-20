import Foundation

/// Scheduling tiers. `system` is the base tier and fires on every tick.
public enum Tier: String, Codable, CaseIterable, Sendable {
    case system, process, slow
}

/// One firing of the scheduler: when it happened and what is due.
public struct Tick: Codable, Equatable, Sendable {
    public var seq: Int
    public var wallMs: Int64
    /// Monotonic time (does not advance during sleep), nanoseconds.
    public var monoNs: UInt64
    /// Awake time since the previous tick; 0 for the first tick.
    public var dtNs: UInt64
    /// Time the machine was asleep since the previous tick.
    public var sleptNs: UInt64
    /// How late the timer fired relative to its deadline (the scheduler-latency canary).
    public var lateNs: Int64
    public var tiers: [Tier]

    public var afterWake: Bool { sleptNs > 1_000_000_000 }

    public init(seq: Int, wallMs: Int64, monoNs: UInt64, dtNs: UInt64, sleptNs: UInt64, lateNs: Int64, tiers: [Tier]) {
        self.seq = seq; self.wallMs = wallMs; self.monoNs = monoNs; self.dtNs = dtNs
        self.sleptNs = sleptNs; self.lateNs = lateNs; self.tiers = tiers
    }
}

/// Cumulative CPU ticks of one core (1 tick = 10 ms). The kernel counters are 32-bit and wrap.
public struct CoreTicks: Codable, Equatable, Sendable {
    public var user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32
    public init(user: UInt32, sys: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user; self.sys = sys; self.idle = idle; self.nice = nice
    }
}

/// Virtual-memory statistics. Gauges are in pages; the rest are cumulative event counts.
public struct VMReading: Codable, Equatable, Sendable {
    public var freePages: UInt64 = 0, activePages: UInt64 = 0, inactivePages: UInt64 = 0, wiredPages: UInt64 = 0
    /// Physical pages occupied by the compressor.
    public var compressorPages: UInt64 = 0
    /// Pages of original data held in compressed form.
    public var compressedPages: UInt64 = 0
    public var faults: UInt64 = 0, pageins: UInt64 = 0, pageouts: UInt64 = 0
    public var swapins: UInt64 = 0, swapouts: UInt64 = 0
    public var compressions: UInt64 = 0, decompressions: UInt64 = 0
    public init() {}
}

/// Cumulative statistics summed over all physical block devices.
public struct DiskReading: Codable, Equatable, Sendable {
    public var readBytes: UInt64 = 0, writeBytes: UInt64 = 0, readOps: UInt64 = 0, writeOps: UInt64 = 0
    /// Summed per-request latency. Exceeds wall time when requests overlap, so
    /// (delta / interval) is the mean queue depth, not a 0-100 % busy figure.
    public var ioTimeNs: UInt64 = 0
    public init() {}
}

/// Cumulative byte counters summed over non-loopback interfaces.
public struct NetReading: Codable, Equatable, Sendable {
    public var inBytes: UInt64 = 0, outBytes: UInt64 = 0
    public init() {}
}

/// Everything the system tier reads on one tick. Raw and cumulative: no interpretation.
public struct SystemReading: Codable, Equatable, Sendable {
    public var cores: [CoreTicks] = []
    public var load1: Double = 0
    public var vm = VMReading()
    public var pressureLevel: Int = 0
    public var memLevelPct: Int = 0
    public var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    public var disk = DiskReading()
    public var net = NetReading()
    public init() {}
}

public struct VolumeReading: Codable, Equatable, Sendable {
    public var mount: String
    public var total: UInt64, free: UInt64
    public init(mount: String, total: UInt64, free: UInt64) { self.mount = mount; self.total = total; self.free = free }
}

/// Slow-tier readings; the latest one is carried forward onto every system sample.
public struct SlowReading: Codable, Equatable, Sendable {
    public var volumes: [VolumeReading] = []
    public var batteryPct: Int?
    public var onBattery = false
    public var lowPower = false
    /// 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermalLevel = 0
    public init() {}
}

/// Static facts about the machine and the current boot.
public struct HostInfo: Codable, Equatable, Sendable {
    public var model = "", chip = ""
    public var pCores = 0, eCores = 0
    public var memBytes: UInt64 = 0
    public var pageSize: UInt64 = 16384
    public var timebaseNum: UInt64 = 1, timebaseDen: UInt64 = 1
    /// For each core index, whether it is a performance core.
    public var coreIsPerformance: [Bool] = []
    public var bootSessionUUID = ""
    public var bootTsMs: Int64 = 0
    public var osVersion = "", osBuild = ""
    public init() {}
}

/// All raw input for one tick. This is the unit that is recorded and replayed.
public struct TickRecord: Codable, Equatable, Sendable {
    public var tick: Tick
    public var system: SystemReading?
    public var slow: SlowReading?
    public var procs: ProcSweep?
    /// The daemon's own pid, so its cost can be tracked like any other process.
    public var selfPid: Int32?
    /// Foreign-process data picked up on this tick, if a new sample was available.
    public var top: TopSample?
    public var ps: PsSample?
    /// Collector state changes to record as events.
    public var notes: [CollectorNote]?
    public var session: SessionReading?
    public init(tick: Tick, system: SystemReading? = nil, slow: SlowReading? = nil, procs: ProcSweep? = nil, selfPid: Int32? = nil) {
        self.tick = tick; self.system = system; self.slow = slow; self.procs = procs; self.selfPid = selfPid
    }
}
