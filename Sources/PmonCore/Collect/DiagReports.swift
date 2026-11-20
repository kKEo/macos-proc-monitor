import Foundation
import CoreServices

/// Watches the system's diagnostic report folders. macOS already writes a report when a process
/// burns CPU for too long, wakes too often, writes too much, hangs or crashes; picking those up
/// costs nothing and names the culprit directly.
public final class DiagReportWatcher {
    public static var defaultDirectories: [String] {
        [NSHomeDirectory() + "/Library/Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports"]
    }

    private let directories: [String]
    private let queue = DispatchQueue(label: "pmon.diagreports", qos: .utility)
    private var stream: FSEventStreamRef?
    private var notes: [CollectorNote] = []
    private var seen = Set<String>()
    /// Reports are written in pieces; wait this long after the first event before reading.
    public var settleSeconds = 1.0

    public init(directories: [String] = DiagReportWatcher.defaultDirectories) {
        self.directories = directories
    }

    public func start() {
        queue.sync {
            guard stream == nil else { return }
            var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
            let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
                let watcher = Unmanaged<DiagReportWatcher>.fromOpaque(info!).takeUnretainedValue()
                let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                for i in 0..<min(count, list.count) where flags[i] & UInt32(kFSEventStreamEventFlagItemIsFile) != 0 {
                    watcher.fileChanged(list[i])
                }
            }
            guard let s = FSEventStreamCreate(nil, callback, &ctx, directories as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
                                              UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)) else { return }
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
    }

    public func stop() {
        queue.sync {
            guard let s = stream else { return }
            FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
            stream = nil
        }
    }

    public func takeNotes() -> [CollectorNote] {
        queue.sync { defer { notes.removeAll() }; return notes }
    }

    // Called on `queue`.
    private func fileChanged(_ path: String) {
        let ext = (path as NSString).pathExtension
        guard ["diag", "ips", "hang", "spin", "crash"].contains(ext), !(path as NSString).lastPathComponent.hasPrefix("."),
              seen.insert(path).inserted else { return }
        if seen.count > 2000 { seen.removeAll() }
        queue.asyncAfter(deadline: .now() + settleSeconds) { [weak self] in
            guard let self, let handle = FileHandle(forReadingAtPath: path) else { return }
            let head = String(decoding: handle.readData(ofLength: 16_384), as: UTF8.self)
            try? handle.close()
            if let note = Self.parse(fileName: (path as NSString).lastPathComponent, head: head) { self.notes.append(note) }
        }
    }

    /// Turn the head of a report into a note. Pure, so it is testable without the file system.
    static func parse(fileName: String, head: String) -> CollectorNote? {
        let ext = (fileName as NSString).pathExtension
        var fields: [String: String] = ["file": fileName]
        var kind = "diag_report"

        if ext == "ips" {
            // First line is a JSON summary: {"app_name":"xctest","bug_type":"309",...}
            guard let line = head.split(separator: "\n").first,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
            let name = (obj["app_name"] as? String) ?? (obj["name"] as? String)
            guard let name else { return nil }
            fields["command"] = name
            if let bug = obj["bug_type"] as? String { fields["bug_type"] = bug; if bug == "309" { kind = "crash" } }
            if let bundle = obj["bundleID"] as? String { fields["bundle_id"] = bundle }
            fields["event"] = kind == "crash" ? "crash" : "report"
        } else {
            // Text header: "Command:          name", "Path:  /full/path", "Event:  cpu usage"
            for line in head.split(separator: "\n").prefix(60) {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                switch key {
                case "Command": fields["command"] = fields["command"] ?? value
                case "Path": fields["path"] = fields["path"] ?? value
                case "Event": fields["event"] = fields["event"] ?? value
                case "Duration": fields["duration"] = fields["duration"] ?? value
                default: break
                }
            }
            guard fields["command"] != nil || fields["path"] != nil else { return nil }
            if ext == "hang" || ext == "spin" || fields["event"]?.contains("hang") == true { kind = "hang" }
            if ext == "crash" { kind = "crash" }
        }
        let json = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
        return CollectorNote(kind: kind, detail: json, exePath: fields["path"], procName: fields["command"])
    }
}
