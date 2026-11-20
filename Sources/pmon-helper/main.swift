import Foundation
import Darwin
import PmonCore

// pmon-helper — the optional root helper. Stateless: answers counter reads for a list of pids
// and runs a fixed set of capture commands, for one user's pmond only. See PmonCore/Helper.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
        usage: pmon-helper --uid <uid> [--client <path to pmond>] [--requirement <code requirement>] [--socket <path>]
        Installed and started by `sudo pmon helper install`; not meant to be run by hand.

        """.utf8))
    exit(2)
}

var uid: uid_t?
var client: String?
var requirement: String?
var socketPath = HelperPaths.socket
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    guard let v = args.next() else { usage() }
    switch a {
    case "--uid": uid = uid_t(v)
    case "--client": client = v
    case "--requirement": requirement = v
    case "--socket": socketPath = v
    default: usage()
    }
}
guard let uid else { usage() }
// As root, never serve without knowing which executable is allowed to ask.
if geteuid() == 0, client == nil, requirement == nil {
    Log.error("refusing to run as root without --client or --requirement")
    exit(2)
}

let server = HelperServer(socketPath: socketPath, policy: HelperPolicy(allowedUid: uid, clientPath: client, requirement: requirement))
do {
    try server.start()
} catch {
    Log.error("cannot listen on \(socketPath): \(error)")
    exit(1)
}
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
term.setEventHandler { server.stop(); exit(0) }
term.resume()
Log.info("pmon-helper \(PmonVersion.string) serving uid \(uid) on \(socketPath)")
server.run()
