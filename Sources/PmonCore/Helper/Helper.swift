import Foundation
import Darwin
import Security
import CPmonSys

// The optional root helper: a stateless server on a Unix socket. It answers two questions,
// "what are the counters of these pids?" and "run capture command X", and nothing else. It has
// no database access, writes no files, and takes no paths or command lines from the client.
//
// Wire format: one JSON object per line in each direction. A successful capture reply is a JSON
// header line `{"ok":true,"bytes":N}` followed by N raw bytes (gzip-compressed tool output).

public enum HelperPaths {
    public static let label = "dev.pmon.helper"
    public static let socket = "/var/run/dev.pmon.helper.sock"
    public static let binary = "/Library/PrivilegedHelperTools/dev.pmon.helper"
    public static let plist = "/Library/LaunchDaemons/dev.pmon.helper.plist"
}

/// What the helper will run. The client chooses a kind and, for two of them, a pid: never a
/// path, flag or command line.
public enum HelperCapture: String, CaseIterable, Sendable {
    case sample, footprint, spindump, powermetrics

    var needsPid: Bool { self == .sample || self == .footprint }

    func command(pid: Int32?) -> (tool: String, args: [String]) {
        switch self {
        case .sample: return ("/usr/bin/sample", ["\(pid ?? 0)", "3", "-mayDie", "-file", "/dev/stdout"])
        case .footprint: return ("/usr/bin/footprint", ["\(pid ?? 0)"])
        case .spindump: return ("/usr/sbin/spindump", ["-notarget", "3", "-noFile", "-noBinary", "-timelimit", "30"])
        case .powermetrics: return ("/usr/bin/powermetrics", ["-n", "1", "-i", "2000", "--samplers", "cpu_power,gpu_power,thermal"])
        }
    }
}

/// Who may talk to the helper.
public struct HelperPolicy: Sendable {
    /// The user the helper was installed for.
    public var allowedUid: uid_t
    /// Executable that may read counters and run captures; nil skips the check (tests).
    public var clientPath: String?
    /// Code-signing requirement the client must satisfy, in addition to having a valid
    /// signature. Meaningful only for a properly signed release; ad-hoc builds leave it nil.
    public var requirement: String?
    public init(allowedUid: uid_t, clientPath: String? = nil, requirement: String? = nil) {
        self.allowedUid = allowedUid; self.clientPath = clientPath; self.requirement = requirement
    }
}

enum HelperLimits {
    static let maxPids = 8192
    static let maxLine = 256 * 1024
    static let maxCaptureBytes = 64 << 20
}

struct HelperRequest: Decodable {
    var op: String
    var pids: [Int32]?
    var kind: String?
    var pid: Int32?
}

// MARK: - Socket helpers

enum Sock {
    static func address(_ path: String) -> sockaddr_un? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        return addr
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var off = 0
        return data.withUnsafeBytes { raw in
            while off < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { if n < 0, errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
    }

    /// Buffered reader for line-then-bytes framing.
    struct Reader {
        let fd: Int32
        var buf = Data()

        mutating func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = Darwin.read(fd, &chunk, chunk.count)
                if n > 0 { buf.append(chunk, count: n); return true }
                if n < 0, errno == EINTR { continue }
                return false
            }
        }

        /// One line without its newline; nil on end of stream, error, or a line over `limit`.
        mutating func line(limit: Int) -> Data? {
            while true {
                if let i = buf.firstIndex(of: 0x0A) {
                    let line = buf.subdata(in: buf.startIndex..<i)
                    buf.removeSubrange(buf.startIndex...i)
                    return line
                }
                guard buf.count <= limit, fill() else { return nil }
            }
        }

        mutating func bytes(_ n: Int) -> Data? {
            while buf.count < n { guard fill() else { return nil } }
            let out = buf.prefix(n)
            buf.removeFirst(n)
            return Data(out)
        }
    }

    static func setTimeout(_ fd: Int32, seconds: Double) {
        var tv = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - Double(Int(seconds))) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
}

// MARK: - Server

public final class HelperServer {
    private let path: String
    private let policy: HelperPolicy
    private var listenFd: Int32 = -1
    private var stopped = false
    private let lock = NSLock()
    private var connections: Set<Int32> = []

    public init(socketPath: String, policy: HelperPolicy) {
        path = socketPath; self.policy = policy
    }

    /// Bind and listen. The socket is owned by the allowed user and closed to everyone else.
    public func start() throws {
        guard var addr = Sock.address(path) else { throw POSIXError(.ENAMETOOLONG) }
        unlink(path)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listenFd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0, listen(listenFd, 4) == 0 else {
            let e = errno; close(listenFd); listenFd = -1
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        chmod(path, 0o600)
        if geteuid() == 0 { chown(path, policy.allowedUid, gid_t(bitPattern: -1)) }
        signal(SIGPIPE, SIG_IGN)
    }

    /// Accept connections until `stop()`. Each connection is served on its own thread.
    public func run() {
        while !stopped {
            let fd = accept(listenFd, nil, nil)
            if fd < 0 { if errno == EINTR { continue }; break }
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    public func stop() {
        stopped = true
        if listenFd >= 0 { shutdown(listenFd, SHUT_RDWR); close(listenFd); listenFd = -1 }
        unlink(path)
        // Cut off clients that are connected: they must notice and fall back.
        lock.lock(); for fd in connections { shutdown(fd, SHUT_RDWR) }; lock.unlock()
    }

    private func reply(_ fd: Int32, _ object: [String: Any]) -> Bool {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return false }
        data.append(0x0A)
        return Sock.writeAll(fd, data)
    }

    private func serve(_ fd: Int32) {
        lock.lock(); connections.insert(fd); lock.unlock()
        defer { lock.lock(); connections.remove(fd); lock.unlock(); close(fd) }
        Sock.setTimeout(fd, seconds: 60)
        // Only the user the helper was installed for, whatever the socket's file mode says.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == policy.allowedUid else {
            _ = reply(fd, ["ok": false, "error": "not allowed"])
            return
        }
        var trusted: Bool?
        var reader = Sock.Reader(fd: fd)
        while let line = reader.line(limit: HelperLimits.maxLine) {
            guard let req = try? JSONDecoder().decode(HelperRequest.self, from: line) else {
                _ = reply(fd, ["ok": false, "error": "bad request"])
                return
            }
            switch req.op {
            case "hello":
                // Open to any process of the allowed user, so `pmon status` can show the helper.
                guard reply(fd, ["ok": true, "version": PmonVersion.string, "root": geteuid() == 0]) else { return }
            case "read", "capture":
                if trusted == nil { trusted = Self.verifyClient(fd, policy: policy) }
                guard trusted == true else {
                    _ = reply(fd, ["ok": false, "error": "client not verified"])
                    return
                }
                guard req.op == "read" ? read(fd, req) : capture(fd, req) else { return }
            default:
                _ = reply(fd, ["ok": false, "error": "unknown op"])
                return
            }
        }
    }

    private func read(_ fd: Int32, _ req: HelperRequest) -> Bool {
        guard let pids = req.pids, pids.count <= HelperLimits.maxPids, pids.allSatisfy({ $0 >= 0 }) else {
            return reply(fd, ["ok": false, "error": "bad pid list"])
        }
        var procs: [ProcReading] = []
        procs.reserveCapacity(pids.count)
        for pid in pids {
            var uid: UInt64 = 0, parent: UInt64 = 0
            guard pmon_unique_id(pid, &uid, &parent) == 0, let r = NativeProcessCollector.read(pid: pid, uid: uid) else { continue }
            procs.append(r)
        }
        guard var data = try? JSONEncoder().encode(HelperReadReply(ok: true, procs: procs)) else { return false }
        data.append(0x0A)
        return Sock.writeAll(fd, data)
    }

    private func capture(_ fd: Int32, _ req: HelperRequest) -> Bool {
        guard let kind = req.kind.flatMap(HelperCapture.init(rawValue:)) else {
            return reply(fd, ["ok": false, "error": "unknown capture"])
        }
        if kind.needsPid, (req.pid ?? 0) <= 0 { return reply(fd, ["ok": false, "error": "bad pid"]) }
        let cmd = kind.command(pid: req.pid)
        // Compress on the way out: `tool | gzip`, with no shell involved.
        let tool = Process(), gzip = Process()
        let between = Pipe(), out = Pipe()
        tool.executableURL = URL(fileURLWithPath: cmd.tool); tool.arguments = cmd.args
        tool.standardOutput = between; tool.standardError = FileHandle.nullDevice; tool.standardInput = FileHandle.nullDevice
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); gzip.arguments = ["-c"]
        gzip.standardInput = between; gzip.standardOutput = out; gzip.standardError = FileHandle.nullDevice
        do { try tool.run(); try gzip.run() } catch { return reply(fd, ["ok": false, "error": "could not run"]) }
        between.fileHandleForWriting.closeFile()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit(); gzip.waitUntilExit()
        guard tool.terminationStatus == 0, data.count <= HelperLimits.maxCaptureBytes else {
            return reply(fd, ["ok": false, "error": "capture failed"])
        }
        return reply(fd, ["ok": true, "bytes": data.count]) && Sock.writeAll(fd, data)
    }

    /// The peer must be running the expected executable with an intact code signature (and, if
    /// configured, satisfy a signing requirement). Identified by audit token, not by pid.
    static func verifyClient(_ fd: Int32, policy: HelperPolicy) -> Bool {
        guard policy.clientPath != nil || policy.requirement != nil else { return true }
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0 else { return false }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: tokenData] as CFDictionary, [], &code) == errSecSuccess,
              let code else { return false }
        var requirement: SecRequirement?
        if let text = policy.requirement {
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return false }
        }
        guard SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        if let expected = policy.clientPath {
            var staticCode: SecStaticCode?
            var url: CFURL?
            guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
                  SecCodeCopyPath(staticCode, [], &url) == errSecSuccess, let url else { return false }
            let actual = (url as URL).resolvingSymlinksInPath().path
            guard actual == URL(fileURLWithPath: expected).resolvingSymlinksInPath().path else { return false }
        }
        return true
    }
}

struct HelperReadReply: Codable {
    var ok: Bool
    var procs: [ProcReading]
}

// MARK: - Client

/// The daemon's side. Every call fails soft: any error marks the helper unavailable, and the
/// caller carries on with the unprivileged sources.
public final class HelperClient {
    private let path: String
    private var fd: Int32 = -1
    private var reader = Sock.Reader(fd: -1)
    private let lock = NSLock()
    /// Version reported by the helper while connected.
    public private(set) var version: String?
    public private(set) var isRoot = false

    public init(socketPath: String = HelperPaths.socket) { path = socketPath }

    public var connected: Bool { lock.lock(); defer { lock.unlock() }; return fd >= 0 }

    /// Connect and greet. Cheap when no helper is installed: the socket file is simply absent.
    @discardableResult
    public func connect() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if fd >= 0 { return true }
        guard access(path, F_OK) == 0, var addr = Sock.address(path) else { return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        Sock.setTimeout(s, seconds: 1)
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(s); return false }
        fd = s; reader = Sock.Reader(fd: s)
        guard let hello = roundTrip(["op": "hello"]), hello["ok"] as? Bool == true else { drop(); return false }
        version = hello["version"] as? String
        isRoot = hello["root"] as? Bool ?? false
        return true
    }

    public func disconnect() { lock.lock(); drop(); lock.unlock() }

    private func drop() {
        if fd >= 0 { close(fd) }
        fd = -1; version = nil
    }

    private func send(_ object: [String: Any]) -> Bool {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
        data.append(0x0A)
        return Sock.writeAll(fd, data)
    }

    private func roundTrip(_ object: [String: Any]) -> [String: Any]? {
        guard send(object), let line = reader.line(limit: 64 << 20) else { return nil }
        return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Counters of the given pids. Nil when the helper is gone or refused; the connection is
    /// then dropped and `connect()` must succeed again before the next use.
    public func read(pids: [Int32]) -> [ProcReading]? {
        lock.lock(); defer { lock.unlock() }
        guard send(["op": "read", "pids": pids]), let line = reader.line(limit: 64 << 20),
              let reply = try? JSONDecoder().decode(HelperReadReply.self, from: line), reply.ok else { drop(); return nil }
        return reply.procs
    }

    /// Gzip-compressed output of one of the fixed capture commands. Uses its own connection,
    /// because a capture takes seconds and must not hold up counter reads.
    public func capture(_ kind: HelperCapture, pid: Int32? = nil, timeout: Double = 60) -> Data? {
        let side = HelperClient(socketPath: path)
        guard side.connect() else { return nil }
        defer { side.disconnect() }
        side.lock.lock(); defer { side.lock.unlock() }
        Sock.setTimeout(side.fd, seconds: timeout)
        var req: [String: Any] = ["op": "capture", "kind": kind.rawValue]
        if let pid { req["pid"] = Int(pid) }
        guard let header = side.roundTrip(req), header["ok"] as? Bool == true, let n = header["bytes"] as? Int,
              n >= 0, n <= HelperLimits.maxCaptureBytes else { return nil }
        return side.reader.bytes(n)
    }
}
