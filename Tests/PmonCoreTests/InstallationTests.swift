import XCTest
@testable import PmonCore

/// Telling a Homebrew installation from one made by `pmon install`, from the executable's path.
final class InstallationTests: XCTestCase {
    func testHomebrewCellarPathsAreRecognised() {
        XCTAssertEqual(Installation.detect(executable: "/opt/homebrew/Cellar/pmon/0.2.2/bin/pmon"), .homebrew(prefix: "/opt/homebrew"))
        XCTAssertEqual(Installation.detect(executable: "/usr/local/Cellar/pmon/0.3.0_1/bin/pmond"), .homebrew(prefix: "/usr/local"))
        let brew = Installation.homebrew(prefix: "/opt/homebrew")
        XCTAssertEqual(brew.toolsDir, "/opt/homebrew/opt/pmon/bin", "the opt link, which survives upgrades")
        XCTAssertEqual(brew.daemonLabel, "sh.brew.pmon", "the label current Homebrew gives a formula's service")
        XCTAssertTrue(Installation.homebrewLabels.contains("homebrew.mxcl.pmon"), "and the one older Homebrew used")
        XCTAssertTrue(brew.upgradeCommand.contains("brew upgrade pmon"))
    }

    func testOtherPathsAreStandalone() {
        for path in ["/Users/me/Library/Application Support/pmon/bin/pmon", "/Users/me/src/pmon/.build/release/pmon",
                     "/opt/homebrew/Cellar/other/1.0/bin/pmon", "/opt/homebrew/Cellar/pmon"] {
            XCTAssertEqual(Installation.detect(executable: path), .standalone, path)
        }
        XCTAssertEqual(Installation.standalone.toolsDir, PmonPaths.binDir)
        XCTAssertEqual(Installation.standalone.daemonLabel, PmonPaths.label)
        XCTAssertEqual(Installation.standalone.upgradeCommand, "pmon update")
    }

    func testSymlinksAreFollowedToTheCellar() throws {
        // Homebrew puts symlinks into <prefix>/bin and <prefix>/opt; the real file is in the Cellar.
        let root = try XCTUnwrap(URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path) + "/pmon-brew-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/Cellar/pmon/0.2.2/bin", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
        fm.createFile(atPath: root + "/Cellar/pmon/0.2.2/bin/pmon", contents: Data())
        try fm.createSymbolicLink(atPath: root + "/bin/pmon", withDestinationPath: "../Cellar/pmon/0.2.2/bin/pmon")
        XCTAssertEqual(Installation.detect(executable: root + "/bin/pmon"), .homebrew(prefix: root))
    }
}
