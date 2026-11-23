import XCTest
@testable import PmonCore

/// The update check without the network: version order, the GitHub answer, the cached state.
final class UpdateTests: XCTestCase {
    func v(_ s: String) -> SemVer { SemVer(s)! }

    func testVersionsParse() {
        XCTAssertEqual(v("0.2.2").description, "0.2.2")
        XCTAssertEqual(v("v1.10.0-rc.1").description, "1.10.0-rc.1")
        for bad in ["", "1.2", "1.2.3.4", "a.b.c", "1.2.3-", "1.2.3-rc..1", "-1.0.0"] { XCTAssertNil(SemVer(bad), bad) }
    }

    func testVersionsOrderAsSemver() {
        let ordered = ["0.1.0", "0.2.0", "0.2.2", "0.10.0", "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta",
                       "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (a, b) in zip(ordered, ordered.dropFirst()) {
            XCTAssertLessThan(v(a), v(b), "\(a) < \(b)")
            XCTAssertFalse(v(b) < v(a), "not \(b) < \(a)")
        }
        XCTAssertEqual(v("v0.2.2"), v("0.2.2"))
    }

    func testNewerRelease() {
        let r = ReleaseInfo(version: "0.2.3", tag: "v0.2.3", pageURL: "")
        XCTAssertTrue(r.isNewer(than: "0.2.2"))
        XCTAssertTrue(r.isNewer(than: "0.2.3-rc.1"))
        XCTAssertFalse(r.isNewer(than: "0.2.3"))
        XCTAssertFalse(r.isNewer(than: "0.3.0"))
        XCTAssertFalse(r.isNewer(than: "dev"))
    }

    func testGitHubReleaseParses() throws {
        let json = """
            {"tag_name": "v0.2.3", "html_url": "https://github.com/o/r/releases/tag/v0.2.3", "draft": false, "prerelease": false,
             "published_at": "2026-11-30T10:00:00Z",
             "assets": [{"name": "pmon-0.2.3.tar.gz", "browser_download_url": "https://x/pmon-0.2.3.tar.gz"},
                        {"name": "pmon-0.2.3.tar.gz.sha256", "browser_download_url": "https://x/pmon-0.2.3.tar.gz.sha256"},
                        {"name": "other.zip", "browser_download_url": "https://x/other.zip"}]}
            """
        let r = try XCTUnwrap(ReleaseInfo.parse(github: Data(json.utf8)))
        XCTAssertEqual(r.version, "0.2.3")
        XCTAssertEqual(r.tag, "v0.2.3")
        XCTAssertEqual(r.tarballURL, "https://x/pmon-0.2.3.tar.gz")
        XCTAssertEqual(r.checksumURL, "https://x/pmon-0.2.3.tar.gz.sha256")
        XCTAssertEqual(r.publishedAt, "2026-11-30T10:00:00Z")
    }

    func testDraftsAndOddTagsAreSkipped() throws {
        XCTAssertNil(try ReleaseInfo.parse(github: Data(#"{"tag_name": "v0.3.0", "draft": true}"#.utf8)))
        XCTAssertNil(try ReleaseInfo.parse(github: Data(#"{"tag_name": "nightly"}"#.utf8)))
        // GitHub's error bodies carry a message instead of a release.
        XCTAssertThrowsError(try ReleaseInfo.parse(github: Data(#"{"message": "API rate limit exceeded"}"#.utf8))) { e in
            XCTAssertTrue("\(e)".contains("rate limit"))
        }
    }

    func testChecksumLine() throws {
        let hex = String(repeating: "ab", count: 32)
        XCTAssertEqual(Updater.checksum(fromShasumLine: "\(hex)  pmon-0.2.3.tar.gz\n"), hex)
        XCTAssertEqual(Updater.checksum(fromShasumLine: hex.uppercased()), hex)
        XCTAssertNil(Updater.checksum(fromShasumLine: "abc  file"))
        XCTAssertNil(Updater.checksum(fromShasumLine: ""))

        let file = NSTemporaryDirectory() + "pmon-sha-\(UUID().uuidString)"
        try Data("abc".utf8).write(to: URL(fileURLWithPath: file))
        defer { try? FileManager.default.removeItem(atPath: file) }
        XCTAssertEqual(try Updater.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testStateRoundTripsAndKnowsWhatIsDue() throws {
        let path = NSTemporaryDirectory() + "pmon-update-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        XCTAssertEqual(UpdateState.load(path: path), UpdateState())
        XCTAssertTrue(UpdateState().isDue(intervalHours: 24, nowMs: 0))

        var s = UpdateState()
        s.checkedMs = 1_000_000
        s.latest = ReleaseInfo(version: "0.9.0", tag: "v0.9.0", pageURL: "https://x")
        try s.save(path: path)
        let back = UpdateState.load(path: path)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.available(current: "0.2.2")?.version, "0.9.0")
        XCTAssertNil(back.available(current: "0.9.0"))

        let hour: Int64 = 3_600_000
        XCTAssertFalse(s.isDue(intervalHours: 24, nowMs: 1_000_000 + 23 * hour))
        XCTAssertTrue(s.isDue(intervalHours: 24, nowMs: 1_000_000 + 24 * hour))
        XCTAssertTrue(s.isDue(intervalHours: 24, nowMs: 0), "a clock set back makes a check due")
    }

    func testScheduledCheckRespectsTheSwitchAndTheInterval() throws {
        let path = NSTemporaryDirectory() + "pmon-update-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var off = UpdateConfig()
        off.autoCheck = false
        XCTAssertNil(Updater.scheduledCheck(config: off, statePath: path, nowMs: 1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "switched off: nothing asked, nothing written")

        // Checked a minute ago: not due, so no request is made.
        var recent = UpdateState()
        recent.checkedMs = 1_000_000
        recent.latest = ReleaseInfo(version: "0.9.0", tag: "v0.9.0", pageURL: "")
        recent.notifiedVersion = "0.9.0"
        try recent.save(path: path)
        XCTAssertNil(Updater.scheduledCheck(config: UpdateConfig(), statePath: path, nowMs: 1_060_000))
        XCTAssertEqual(UpdateState.load(path: path), recent)
    }

    func testConfigDefaultsAndOverrides() throws {
        let d = try JSONDecoder().decode(Config.self, from: Data("{}".utf8)).updates
        XCTAssertEqual(d, UpdateConfig())
        XCTAssertTrue(d.autoCheck)
        let c = try JSONDecoder().decode(Config.self, from: Data(#"{"updates": {"autoCheck": false, "repository": "me/fork"}}"#.utf8)).updates
        XCTAssertFalse(c.autoCheck)
        XCTAssertEqual(c.repository, "me/fork")
        XCTAssertEqual(c.checkIntervalHours, 24)
    }
}
