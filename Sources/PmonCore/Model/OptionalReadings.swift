import Foundation

/// Cumulative GPU time of one process, summed over its accelerator clients.
public struct GpuClient: Codable, Equatable, Sendable {
    public var pid: Int32
    public var ns: UInt64
    public init(pid: Int32, ns: UInt64) { self.pid = pid; self.ns = ns }
}

/// A finished capture: the file it left behind and a short summary. Carried in the tick record
/// so that the `capture` row is written by the pipeline, and a replay reproduces it.
public struct CaptureResult: Codable, Equatable, Sendable {
    public var episodeId: Int64?
    /// stack | procs | footprint | network
    public var kind: String
    public var pid: Int32?
    public var path: String
    public var bytes: Int
    public var summary: String
    /// Wall time the capture took.
    public var costMs: Int
    public init(episodeId: Int64?, kind: String, pid: Int32?, path: String, bytes: Int, summary: String, costMs: Int) {
        self.episodeId = episodeId; self.kind = kind; self.pid = pid; self.path = path
        self.bytes = bytes; self.summary = summary; self.costMs = costMs
    }
}

/// Short-lived processes of one executable, started (directly or not) by one long-lived process.
public struct ShortLivedGroup: Codable, Equatable, Sendable {
    public var path: String
    public var name: String
    /// The nearest ancestor that was already running when the scan began.
    public var parentPid: Int32
    public var parentName: String
    /// Distinct processes seen.
    public var count: Int
    /// Times a process of this group was seen alive.
    public var sightings: Int
    /// Time these processes existed while the scan ran (sightings x the real time between
    /// looks). An upper bound on the CPU they used, available for every process.
    public var aliveMs: Int64
    /// CPU time at the last sighting, summed: a lower bound, and only for readable processes.
    public var cpuMs: Int64
    public init(path: String, name: String, parentPid: Int32, parentName: String, count: Int, sightings: Int, aliveMs: Int64, cpuMs: Int64) {
        self.path = path; self.name = name; self.parentPid = parentPid; self.parentName = parentName
        self.count = count; self.sightings = sightings; self.aliveMs = aliveMs; self.cpuMs = cpuMs
    }
}

/// Result of one fast scan for processes that live and die between regular sweeps.
public struct ShortLivedScan: Codable, Equatable, Sendable {
    public var durationMs: Int
    public var intervalMs: Int
    /// All processes born during the scan, short-lived or not.
    public var births: Int
    /// CPU the scan itself used.
    public var costCpuMs: Int
    public var groups: [ShortLivedGroup]
    public init(durationMs: Int, intervalMs: Int, births: Int, costCpuMs: Int, groups: [ShortLivedGroup]) {
        self.durationMs = durationMs; self.intervalMs = intervalMs; self.births = births
        self.costCpuMs = costCpuMs; self.groups = groups
    }
}
