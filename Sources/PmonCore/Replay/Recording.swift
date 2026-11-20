import Foundation

/// Recording format: newline-delimited JSON. The first line is the header (host facts),
/// every following line is one `TickRecord`.
struct RecordingHeader: Codable {
    var format = 1
    var host: HostInfo
}

/// Appends raw tick records to a file so a run can be replayed later.
public final class Recorder {
    private let handle: FileHandle
    private let encoder = JSONEncoder()
    private let capBytes: Int
    private var written = 0
    public private(set) var capReached = false

    public init(path: String, host: HostInfo, capMB: Int = 256) throws {
        guard FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let h = FileHandle(forWritingAtPath: path) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path])
        }
        handle = h
        capBytes = capMB << 20
        encoder.outputFormatting = [.sortedKeys]
        try writeLine(encoder.encode(RecordingHeader(host: host)))
    }

    public func append(_ rec: TickRecord) throws {
        guard !capReached else { return }
        try writeLine(encoder.encode(rec))
        if written >= capBytes { capReached = true }
    }

    public func close() { try? handle.close() }

    private func writeLine(_ data: Data) throws {
        try handle.write(contentsOf: data + Data([0x0A]))
        written += data.count + 1
    }
}

/// Feeds a recording through a pipeline, exactly as the live daemon would have.
public enum Replayer {
    /// Returns the number of tick records replayed.
    @discardableResult
    public static func replay(recording path: String, into db: Database, thresholds: Thresholds = Thresholds()) throws -> Int {
        guard let text = try? readText(path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path])
        }
        let decoder = JSONDecoder()
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let first = lines.next() else { return 0 }
        let header = try decoder.decode(RecordingHeader.self, from: Data(first.utf8))
        let pipeline = try Pipeline(db: db, host: header.host, thresholds: thresholds)
        var n = 0
        while let line = lines.next() {
            try pipeline.ingest(decoder.decode(TickRecord.self, from: Data(line.utf8)))
            n += 1
        }
        return n
    }

    /// Read a recording, transparently decompressing `.gz` files (recordings compress about tenfold).
    static func readText(_ path: String) throws -> String {
        guard path.hasSuffix(".gz") else { return try String(contentsOfFile: path, encoding: .utf8) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gunzip")
        p.arguments = ["-c", path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
        return String(decoding: data, as: UTF8.self)
    }
}
