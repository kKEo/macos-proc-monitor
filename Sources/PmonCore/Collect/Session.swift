import AppKit
import CoreGraphics
import IOKit.ps

/// Reads the login session: frontmost app, input idle time, lock and display state, power.
/// Works from a UI-less LaunchAgent (verified in phase 0); needs the main run loop to be running
/// for app-activation notifications to arrive.
public final class SessionCollector {
    private let lock = NSLock()
    private var front: NSRunningApplication?
    private var observer: NSObjectProtocol?

    public init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.lock.lock(); self?.front = app; self?.lock.unlock()
        }
    }

    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    public func collect() -> SessionReading {
        var r = SessionReading()
        lock.lock(); var app = front; lock.unlock()
        if app == nil || app!.isTerminated { app = NSWorkspace.shared.frontmostApplication }
        // Only regular apps count as "in focus"; accessory and background agents can be frontmost
        // too, which means no app on this Mac has the user's attention.
        if let app, !app.isTerminated, app.activationPolicy == .regular {
            r.frontPid = app.processIdentifier
            r.frontBundleId = app.bundleIdentifier
        }
        r.idleSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!)
        if let session = CGSessionCopyCurrentDictionary() as? [String: Any] {
            r.locked = session["CGSSessionScreenIsLocked"] as? Bool ?? false
        }
        r.displayOn = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: r.thermalLevel = 0
        case .fair: r.thermalLevel = 1
        case .serious: r.thermalLevel = 2
        case .critical: r.thermalLevel = 3
        @unknown default: r.thermalLevel = 0
        }
        r.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        r.onBattery = (IOPSGetProvidingPowerSourceType(blob).takeUnretainedValue() as String) == kIOPMBatteryPowerKey
        return r
    }
}
