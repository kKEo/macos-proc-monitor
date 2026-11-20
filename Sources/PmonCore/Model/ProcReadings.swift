import Foundation

/// Cumulative counters of one process the daemon is allowed to read natively.
/// Times are nanoseconds (already converted from Mach units); sizes are bytes.
public struct ProcReading: Codable, Equatable, Sendable {
    public var pid: Int32 = 0
    /// Kernel-unique id: the identity of this process instance. Pids are reused; this is not.
    public var uid: UInt64 = 0
    /// Monotonic time at which the process started (same clock as `Tick.monoNs`).
    public var startNs: UInt64 = 0
    public var userNs: UInt64 = 0, sysNs: UInt64 = 0
    /// CPU time spent on performance cores.
    public var pNs: UInt64 = 0
    /// CPU time by QoS group: foreground (interactive, initiated, default, legacy), utility,
    /// background (background, maintenance). Phase 0 showed finer classes are not reliable.
    public var fgNs: UInt64 = 0, utilNs: UInt64 = 0, bgNs: UInt64 = 0
    /// Time threads were runnable, *including* time on a core. Wait = runnableNs - CPU time.
    public var runnableNs: UInt64 = 0
    public var footprint: UInt64 = 0, rss: UInt64 = 0
    public var pageins: UInt64 = 0
    public var diskRead: UInt64 = 0, diskWrite: UInt64 = 0
    public var energyNj: UInt64 = 0
    public var idleWakeups: UInt64 = 0
    public var instructions: UInt64 = 0
    public var threads: Int32 = 0
    /// Context switches. A 32-bit kernel counter that wraps.
    public var csw: UInt32 = 0
    public init() {}

    public var cpuNs: UInt64 { userNs + sysNs }
}

/// A process the daemon can see but not read (owned by another user).
public struct ProcRef: Codable, Equatable, Sendable {
    public var pid: Int32
    public var uid: UInt64
    public init(pid: Int32, uid: UInt64) { self.pid = pid; self.uid = uid }
}

/// Descriptive facts about a process instance, read once when it is first seen.
public struct ProcIdentity: Codable, Equatable, Sendable {
    public var pid: Int32 = 0
    public var uid: UInt64 = 0
    public var parentUid: UInt64 = 0
    public var ppid: Int32 = 0
    public var userId: UInt32 = 0
    public var startTsMs: Int64 = 0
    public var path = ""
    public var name = ""
    public var translated = false
    /// Pid of the app responsible for this process; nil when unknown (always nil for foreign processes).
    public var responsiblePid: Int32?
    public var coalitionId: UInt64?
    /// Whether the daemon can read this process's counters natively.
    public var own = false
    public init() {}
}

/// Everything one process sweep produced.
public struct ProcSweep: Codable, Equatable, Sendable {
    public var procs: [ProcReading] = []
    public var foreign: [ProcRef] = []
    /// Identities of process instances not reported in the previous sweep.
    public var identities: [ProcIdentity] = []
    /// How long the sweep took: input to the self-limiter.
    public var durationNs: UInt64 = 0
    public init() {}
}
