import Foundation

/// One process row of a `top` sample. Sizes in bytes, CPU time in nanoseconds.
/// `cpuNs`, `pageins`, `csw`, `idlew` and `faults` are cumulative; `instrs` and `cycles`
/// are per-interval (phase 0 finding); `mem`, `cmprs` and `threads` are gauges.
public struct TopRow: Codable, Equatable, Sendable {
    public var pid: Int32 = 0
    public var cpuNs: UInt64 = 0
    /// TIME was shown in whole seconds (top does this past one hour of CPU time).
    public var coarse = false
    public var mem: UInt64 = 0, cmprs: UInt64 = 0
    public var pageins: UInt64 = 0, csw: UInt64 = 0, idlew: UInt64 = 0, faults: UInt64 = 0
    public var instrs: UInt64 = 0, cycles: UInt64 = 0
    public var threads: Int32 = 0
    public init() {}
}

/// One complete sample from the `top` stream, reduced to the processes we cannot read natively.
public struct TopSample: Codable, Equatable, Sendable {
    /// Monotonic time at which the sample started arriving.
    public var monoNs: UInt64
    public var rows: [TopRow]
    public init(monoNs: UInt64, rows: [TopRow]) { self.monoNs = monoNs; self.rows = rows }
}

/// Cumulative CPU time of one process as reported by `ps` (hundredths-of-a-second resolution).
public struct PsRow: Codable, Equatable, Sendable {
    public var pid: Int32
    public var userNs: UInt64, sysNs: UInt64
    public init(pid: Int32, userNs: UInt64, sysNs: UInt64) { self.pid = pid; self.userNs = userNs; self.sysNs = sysNs }
}

public struct PsSample: Codable, Equatable, Sendable {
    public var monoNs: UInt64
    public var rows: [PsRow]
    public init(monoNs: UInt64, rows: [PsRow]) { self.monoNs = monoNs; self.rows = rows }
}

/// Something a collector wants on the record: stored as an `event` row. Carried in the tick
/// record (rather than written directly) so a replay reproduces it.
public struct CollectorNote: Codable, Equatable, Sendable {
    public var kind: String
    public var value: Int64?
    public var detail: String?
    /// Executable path or process name the note is about, used to attach it to an app.
    public var exePath: String?
    public var procName: String?
    public init(kind: String, value: Int64? = nil, detail: String? = nil, exePath: String? = nil, procName: String? = nil) {
        self.kind = kind; self.value = value; self.detail = detail; self.exePath = exePath; self.procName = procName
    }
}
