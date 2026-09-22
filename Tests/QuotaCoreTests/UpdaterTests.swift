import XCTest
@testable import QuotaCore

final class UpdateFeedTests: XCTestCase {
    private let page = URL(string: "https://example.com/releases")!

    func testParsesAGitHubRelease() throws {
        let json = """
        {"tag_name":"v0.3.0","html_url":"https://github.com/o/r/releases/tag/v0.3.0",
         "body":"notes here",
         "assets":[{"name":"QuotaBar-0.3.0.dmg","browser_download_url":"https://x/a.dmg"},
                   {"name":"QuotaBar-0.3.0.zip","browser_download_url":"https://x/a.zip"}]}
        """
        let release = try XCTUnwrap(UpdateFeed.parseGitHub(Data(json.utf8), page: page))

        XCTAssertEqual(release.version, "0.3.0", "the v prefix is stripped")
        // The zip, not the dmg: installing unpacks a bundle.
        XCTAssertEqual(release.downloadURL.absoluteString, "https://x/a.zip")
        XCTAssertEqual(release.notes, "notes here")
    }

    func testReadsWhenAReleaseWasPublished() throws {
        let json = """
        {"tag_name":"v0.5.3","published_at":"2026-09-13T01:45:33Z",
         "assets":[{"name":"QuotaBar-0.5.3.zip","browser_download_url":"https://x/a.zip"}]}
        """
        let release = try XCTUnwrap(UpdateFeed.parseGitHub(Data(json.utf8), page: page))
        XCTAssertEqual(release.publishedAt, ISO8601DateFormatter().date(from: "2026-09-13T01:45:33Z"))
        XCTAssertEqual(release.manualDownloadURL.absoluteString, "https://quota.bar/download/QuotaBar-0.5.3.dmg")
    }

    func testAGitHubReleaseWithNoZipIsUnusable() {
        let json = """
        {"tag_name":"v0.3.0","assets":[{"name":"x.dmg","browser_download_url":"https://x/a.dmg"}]}
        """
        XCTAssertNil(UpdateFeed.parseGitHub(Data(json.utf8), page: page))
    }

    func testParsesACustomFeed() throws {
        let json = """
        {"version":"1.2.0","url":"https://mine.example/QuotaBar-1.2.0.zip","notes":"hi"}
        """
        let release = try XCTUnwrap(UpdateFeed.parseCustom(Data(json.utf8), page: page))

        XCTAssertEqual(release.version, "1.2.0")
        XCTAssertEqual(release.downloadURL.absoluteString, "https://mine.example/QuotaBar-1.2.0.zip")
        XCTAssertEqual(release.pageURL, page, "falls back to the feed's own page")
    }

    /// latest.json as Scripts/publish_release.sh writes it: the extra fields
    /// are for people and scripts, the app reads version and url.
    func testParsesTheQuotaBarMirrorFeed() throws {
        let json = """
        {"version":"0.5.0","url":"https://quota.bar/download/QuotaBar-0.5.0.zip","sha256":"620f",
         "dmg":"https://quota.bar/download/QuotaBar-0.5.0.dmg","page":"https://quota.bar/changelog.html",
         "github":"https://github.com/gentpan/QuotaBar/releases/tag/v0.5.0"}
        """
        let release = try XCTUnwrap(UpdateFeed.mirror.parse(Data(json.utf8)))
        XCTAssertEqual(release.downloadURL, UpdateFeed.mirrorDownload(version: "0.5.0"))
        XCTAssertEqual(release.pageURL.absoluteString, "https://quota.bar/changelog.html")
    }

    func testOnlyThisProjectsReleasesAreMirrored() {
        XCTAssertTrue(UpdateFeed.default.isMirrored)
        XCTAssertTrue(UpdateFeed.github(repo: "gentpan/quotabar").isMirrored, "a feed saved before the repository was renamed in case")
        XCTAssertFalse(UpdateFeed.github(repo: "someone/fork").isMirrored)
        XCTAssertFalse(UpdateFeed.mirror.isMirrored)
    }

    /// Whichever side answered the check, a release of this project carries
    /// both addresses, so a download can fall through from one to the other.
    func testAMirrorReleaseGainsItsGitHubAsset() throws {
        let json = """
        {"version":"0.5.0","url":"https://quota.bar/download/QuotaBar-0.5.0.zip","page":"https://quota.bar/changelog.html"}
        """
        let release = try XCTUnwrap(UpdateFeed.mirror.parse(Data(json.utf8)))
        let both = UpdateFeed.default.withBothCopies(of: release)
        XCTAssertEqual(both.mirrorURL, UpdateFeed.mirrorDownload(version: "0.5.0"))
        XCTAssertEqual(
            both.downloadURL.absoluteString,
            "https://github.com/QuotaBar/QuotaBar/releases/download/v0.5.0/QuotaBar-0.5.0.zip")
        XCTAssertEqual(both.pageURL, release.pageURL, "the page the mirror named still stands")
    }

    func testAGitHubReleaseGainsItsMirrorCopy() throws {
        let json = """
        {"tag_name":"v0.5.0","assets":[{"name":"QuotaBar-0.5.0.zip","browser_download_url":"https://x/a.zip"}]}
        """
        let release = try XCTUnwrap(UpdateFeed.default.parse(Data(json.utf8)))
        let both = UpdateFeed.default.withBothCopies(of: release)
        XCTAssertEqual(both.downloadURL.absoluteString, "https://x/a.zip")
        XCTAssertEqual(both.mirrorURL, UpdateFeed.mirrorDownload(version: "0.5.0"))
    }

    func testAForksReleaseHasNoMirror() throws {
        let fork = UpdateFeed.github(repo: "someone/fork")
        let json = """
        {"tag_name":"v9.0.0","assets":[{"name":"QuotaBar-9.0.0.zip","browser_download_url":"https://x/fork.zip"}]}
        """
        let release = try XCTUnwrap(fork.parse(Data(json.utf8)))
        XCTAssertNil(fork.withBothCopies(of: release).mirrorURL, "quota.bar has no copy of someone else's build")
    }

    func testTheNewerOfTwoAnswersWinsAndTheMirrorOnATie() {
        let page = URL(string: "https://example.com")!
        let mirror = UpdateRelease(version: "0.5.0", downloadURL: UpdateFeed.mirrorDownload(version: "0.5.0"), pageURL: page)
        let beta = UpdateRelease(version: "0.6.0-beta.1", downloadURL: URL(string: "https://x/b.zip")!, pageURL: page)
        let same = UpdateRelease(version: "0.5.0", downloadURL: URL(string: "https://x/a.zip")!, pageURL: page)
        XCTAssertEqual(Updater.newer(mirror, beta)?.version, "0.6.0-beta.1")
        XCTAssertEqual(Updater.newer(mirror, same)?.downloadURL, mirror.downloadURL)
        XCTAssertEqual(Updater.newer(nil, same)?.version, "0.5.0")
        XCTAssertEqual(Updater.newer(mirror, nil)?.version, "0.5.0")
        XCTAssertNil(Updater.newer(nil, nil))
    }

    func testCustomFeedNeedsBothFields() {
        XCTAssertNil(UpdateFeed.parseCustom(Data(#"{"version":"1.0"}"#.utf8), page: page))
        XCTAssertNil(UpdateFeed.parseCustom(Data(#"{"url":"https://x/a.zip"}"#.utf8), page: page))
    }

    // MARK: Config round-trip

    func testOwnerSlashRepoMeansGitHub() throws {
        // The repository's old path: a config written before the move still
        // parses, and still names the repository it named then.
        let feed = try XCTUnwrap(UpdateFeed(configValue: "gentpan/QuotaBar"))
        XCTAssertEqual(feed, .github(repo: "gentpan/QuotaBar"))
        XCTAssertTrue(feed.isMirrored, "the mirror has those releases too")
        XCTAssertEqual(feed.configValue, "gentpan/QuotaBar")
        XCTAssertEqual(
            feed.requestURL.absoluteString,
            "https://api.github.com/repos/gentpan/QuotaBar/releases/latest")
    }

    func testAURLMeansACustomServer() throws {
        let feed = try XCTUnwrap(UpdateFeed(configValue: "https://mine.example/appcast.json"))
        XCTAssertEqual(feed, .custom(URL(string: "https://mine.example/appcast.json")!))
        XCTAssertEqual(feed.configValue, "https://mine.example/appcast.json")
    }

    func testRejectsMalformedConfigRatherThanBuildingADeadFeed() {
        // A typo must fail loudly at parse time, not become a feed that
        // silently never returns anything.
        XCTAssertNil(UpdateFeed(configValue: "quotabar"))
        XCTAssertNil(UpdateFeed(configValue: "a/b/c"))
        XCTAssertNil(UpdateFeed(configValue: "  "))
        XCTAssertNil(UpdateFeed(configValue: "/leading"))
    }
}

final class UpdateUserAgentTests: XCTestCase {
    /// The shape quota.bar parses: product/version, then the macOS
    /// major.minor and the chip in parentheses.
    func testNamesTheVersionSystemAndChip() {
        let os = OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 2)
        XCTAssertEqual(
            Updater.userAgent(version: "0.5.14", os: os, arch: "arm64"),
            "QuotaBar/0.5.14 (macOS 26.1; arm64)")
        XCTAssertEqual(
            Updater.userAgent(version: "0.6.0-beta.1", os: os, arch: "x86_64"),
            "QuotaBar/0.6.0-beta.1 (macOS 26.1; x86_64)")
    }

    func testAnUnusableVersionBecomesDev() {
        let os = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(Updater.userAgent(version: "", os: os, arch: "arm64"), "QuotaBar/dev (macOS 15.0; arm64)")
        XCTAssertEqual(Updater.userAgent(version: "1.0 (测试)", os: os, arch: "arm64"), "QuotaBar/1.0 (macOS 15.0; arm64)")
    }

    func testTheRunningMachineFillsTheDefaults() throws {
        let agent = Updater.userAgent(version: "0.5.14")
        let pattern = #"^QuotaBar/0\.5\.14 \(macOS \d+\.\d+; (arm64|x86_64)\)$"#
        XCTAssertNotNil(agent.range(of: pattern, options: .regularExpression), agent)
        XCTAssertTrue(["arm64", "x86_64"].contains(Updater.architecture))
    }
}

final class UpdateVerificationTests: XCTestCase {
    func testReadsTheTeamIdentifierFromCodesignOutput() {
        let output = """
        Executable=/Applications/QuotaBar.app/Contents/MacOS/QuotaBar
        Authority=Developer ID Application: GiantAccel, LLC (WPDUNPG5N8)
        TeamIdentifier=WPDUNPG5N8
        """
        XCTAssertEqual(Updater.teamIdentifier(in: output), "WPDUNPG5N8")
    }

    func testAnAdHocSignatureHasNoTeam() {
        // "not set" is what codesign prints for ad-hoc, and it must not be
        // treated as a team that could match.
        let output = "CodeDirectory v=20400 flags=0x2(adhoc)\nTeamIdentifier=not set"
        XCTAssertNil(Updater.teamIdentifier(in: output))
    }

    func testUnsignedOutputHasNoTeam() {
        XCTAssertNil(Updater.teamIdentifier(in: "code object is not signed at all"))
    }

    /// The guarantee the updater rests on: a bundle that is not signed by our
    /// team is refused. Uses a real unsigned bundle rather than a stub.
    func testRefusesABundleWeDidNotSign() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-verify-\(UUID().uuidString)")
        let bundle = root.appendingPathComponent("Fake.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "#!/bin/sh\necho hi\n".write(
            to: bundle.appendingPathComponent("Contents/MacOS/Fake"),
            atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try Updater.verify(bundle)) { error in
            guard case UpdateError.notSignedByUs = error as? UpdateError ?? .downloadFailed else {
                return XCTFail("expected a signing rejection, got \(error)")
            }
        }
    }

    func testEveryErrorExplainsItself() {
        let errors: [UpdateError] = [
            .downloadFailed, .extractionFailed, .notSignedByUs(found: "OTHER"),
            .notNotarized, .installFailed("disk full"),
        ]
        for error in errors {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "\(error) has no message")
        }
    }
}

final class UpdateConfigTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-upd-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testDefaultsToTheProjectRepository() {
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        XCTAssertEqual(store.updateFeed, .github(repo: "QuotaBar/QuotaBar"))
        XCTAssertTrue(store.checksForUpdates)
    }

    func testRoundTripsACustomServer() {
        let keychain = MemoryCredentialStorage()
        let first = ConfigStore(fileURL: fileURL, credentials: keychain)
        first.updateFeed = .custom(URL(string: "https://mine.example/appcast.json")!)
        first.checksForUpdates = false

        let second = ConfigStore(fileURL: fileURL, credentials: keychain)
        XCTAssertEqual(second.updateFeed, .custom(URL(string: "https://mine.example/appcast.json")!))
        XCTAssertFalse(second.checksForUpdates)
    }

    func testAMalformedStoredFeedFallsBackRatherThanBreaking() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"enabled":["codex"],"updateFeed":"not a feed","refreshMinutes":7}"#
            .write(to: fileURL, atomically: true, encoding: .utf8)

        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())

        XCTAssertEqual(store.updateFeed, .default, "a bad edit must not disable updates")
        XCTAssertEqual(store.refreshMinutes, 7, "the rest of the file still loads")
    }
}

final class HomebrewOwnershipTests: XCTestCase {
    func testHomebrewOwnsOnlyTheVersionItInstalled() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("caskroom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("0.3.0"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(Updater.isManagedByHomebrew(version: "0.3.0", caskroots: [root.path]))
        XCTAssertFalse(Updater.isManagedByHomebrew(version: "0.3.3", caskroots: [root.path]))
        XCTAssertFalse(Updater.isManagedByHomebrew(version: nil, caskroots: [root.path]))
        XCTAssertFalse(Updater.isManagedByHomebrew(version: "0.3.0", caskroots: ["/nonexistent/caskroom"]))
    }
}
