import Foundation
import Dispatch

/// Decides which tiers are due on each wake-up and measures elapsed and slept time.
/// Pure logic over a `Clock`; the timer that drives it lives in `Scheduler`.
public struct TickPlanner {
    public private(set) var intervalsNs: [Tier: UInt64]
    private var lastFired: [Tier: UInt64] = [:]
    private var prevMono: UInt64?
    private var prevCont: UInt64?
    private var seq = 0

    public init(systemSeconds: Double, processSeconds: Double, slowSeconds: Double) {
        intervalsNs = [:]
        setIntervals(systemSeconds: systemSeconds, processSeconds: processSeconds, slowSeconds: slowSeconds)
    }

    /// Change cadence at run time (adaptive cadence). Other tiers are never faster than the system tier.
    public mutating func setIntervals(systemSeconds: Double, processSeconds: Double, slowSeconds: Double) {
        let base = max(systemSeconds, 0.5)
        intervalsNs = [.system: UInt64(base * 1e9),
                       .process: UInt64(max(processSeconds, base) * 1e9),
                       .slow: UInt64(max(slowSeconds, base) * 1e9)]
    }

    /// Monotonic time of the next wake-up.
    public func nextDeadline(now: UInt64) -> UInt64 {
        guard let last = lastFired[.system] else { return now }
        return max(now, last + intervalsNs[.system]!)
    }

    /// Record a wake-up. `deadlineNs` is when the timer was meant to fire.
    public mutating func plan(clock: Clock, deadlineNs: UInt64?) -> Tick {
        let mono = clock.monotonicNs, cont = clock.continuousNs
        var dt: UInt64 = 0, slept: UInt64 = 0
        if let pm = prevMono, let pc = prevCont {
            dt = mono &- pm
            let contDt = cont &- pc
            slept = contDt > dt ? contDt - dt : 0
        }
        // A tier is due when its interval has elapsed, with a tolerance so that a tier at a
        // multiple of the base interval fires on the expected base tick despite timer jitter.
        let slack = intervalsNs[.system]! / 10
        var due: [Tier] = []
        for tier in Tier.allCases {
            if let last = lastFired[tier], mono + slack < last + intervalsNs[tier]! { continue }
            due.append(tier)
            lastFired[tier] = mono
        }
        let late = deadlineNs.map { Int64(mono) - Int64($0) } ?? 0
        let tick = Tick(seq: seq, wallMs: clock.wallMs, monoNs: mono, dtNs: dt, sleptNs: slept, lateNs: late, tiers: due)
        seq += 1; prevMono = mono; prevCont = cont
        return tick
    }
}

/// Drives a `TickPlanner` from a strict (zero-leeway) timer.
///
/// The timer runs at `userInitiated` QoS so that its lateness is a meaningful canary for
/// scheduler latency; the tick handler runs on a serial `utility` queue so collection never
/// competes with the user's work.
public final class Scheduler {
    private let clock: SystemClock
    private var planner: TickPlanner
    private let timerQueue = DispatchQueue(label: "pmon.scheduler.timer", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "pmon.scheduler.work", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let handler: (Tick) -> Void

    public init(clock: SystemClock, planner: TickPlanner, handler: @escaping (Tick) -> Void) {
        self.clock = clock; self.planner = planner; self.handler = handler
    }

    public func start() {
        timerQueue.async { self.arm(deadline: self.clock.monotonicNs) }
    }

    /// Stop ticking and wait for an in-flight handler to finish.
    public func stop() {
        timerQueue.sync { timer?.cancel(); timer = nil }
        workQueue.sync {}
    }

    /// Change cadence. Takes effect at once: the pending timer is re-armed for the new interval,
    /// so switching to a faster cadence does not wait out the old, longer one.
    public func setIntervals(systemSeconds: Double, processSeconds: Double, slowSeconds: Double) {
        timerQueue.async {
            self.planner.setIntervals(systemSeconds: systemSeconds, processSeconds: processSeconds, slowSeconds: slowSeconds)
            guard self.timer != nil else { return }
            self.arm(deadline: self.planner.nextDeadline(now: self.clock.monotonicNs))
        }
    }

    private func arm(deadline: UInt64) {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        // DispatchTime's uptime nanoseconds share the clock used by `monotonicNs`.
        t.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let tick = self.planner.plan(clock: self.clock, deadlineNs: deadline)
            self.workQueue.async { self.handler(tick) }
            self.arm(deadline: self.planner.nextDeadline(now: self.clock.monotonicNs))
        }
        timer?.cancel()
        timer = t
        t.resume()
    }
}
