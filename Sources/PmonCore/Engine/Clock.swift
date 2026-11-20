import Foundation
import Darwin

/// Time source. Abstracted so scheduling and sleep handling can be tested deterministically.
public protocol Clock: AnyObject {
    /// Wall-clock time, Unix milliseconds.
    var wallMs: Int64 { get }
    /// Monotonic nanoseconds; stops while the machine sleeps.
    var monotonicNs: UInt64 { get }
    /// Monotonic nanoseconds; keeps running while the machine sleeps.
    var continuousNs: UInt64 { get }
}

public enum MachTime {
    public static let timebase: (num: UInt64, den: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(info.denom))
    }()

    /// Convert Mach time units to nanoseconds. Kernel CPU-time counters are in these units.
    @inline(__always) public static func ns(_ units: UInt64) -> UInt64 {
        // Full-width multiply so large values do not overflow; saturate if the result cannot fit
        // (more than 584 years of nanoseconds), since trapping would take the daemon down.
        let (hi, lo) = units.multipliedFullWidth(by: timebase.num)
        guard hi < timebase.den else { return .max }
        return timebase.den.dividingFullWidth((hi, lo)).quotient
    }
}

public final class SystemClock: Clock {
    public init() {}
    public var wallMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
    public var monotonicNs: UInt64 { MachTime.ns(mach_absolute_time()) }
    public var continuousNs: UInt64 { MachTime.ns(mach_continuous_time()) }
}

/// Manually driven clock for tests and replay.
public final class FakeClock: Clock {
    public private(set) var wallMs: Int64
    public private(set) var monotonicNs: UInt64
    public private(set) var continuousNs: UInt64

    public init(wallMs: Int64 = 1_800_000_000_000, monotonicNs: UInt64 = 1_000_000_000) {
        self.wallMs = wallMs
        self.monotonicNs = monotonicNs
        self.continuousNs = monotonicNs
    }

    /// Time passes while awake.
    public func advance(seconds: Double) {
        let ns = UInt64(seconds * 1e9)
        monotonicNs += ns; continuousNs += ns; wallMs += Int64(seconds * 1000)
    }

    /// Time passes while asleep: only wall and continuous time move.
    public func sleep(seconds: Double) {
        continuousNs += UInt64(seconds * 1e9); wallMs += Int64(seconds * 1000)
    }
}
