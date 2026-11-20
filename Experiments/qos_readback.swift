// 0.2.5 follow-up — does a thread asking for a high QoS actually get it in this launch context?
import Foundation
let names: [UInt32: String] = [0x21: "userInteractive", 0x19: "userInitiated", 0x15: "default", 0x11: "utility", 0x09: "background", 0: "unspecified"]
print("main thread qos:", names[qos_class_main().rawValue] ?? "?", " self:", names[qos_class_self().rawValue] ?? "?")
for (n, q) in [("userInteractive", QualityOfService.userInteractive), ("userInitiated", .userInitiated), ("default", .default), ("utility", .utility)] {
    let s = DispatchSemaphore(value: 0)
    let t = Thread { print("requested \(n) -> effective qos_class_self:", names[qos_class_self().rawValue] ?? "?"); s.signal() }
    t.qualityOfService = q; t.start(); s.wait()
}
