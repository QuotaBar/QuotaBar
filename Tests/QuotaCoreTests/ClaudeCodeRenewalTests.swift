import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Having Claude Code renew its own sign-in: the trust dialog answered only
/// toward "Yes", the screen read through its escape sequences, the binary
/// found where installers put it, and a launch at most every half hour.
final class ClaudeCodeRenewalTests: XCTestCase {
    /// Claude Code 2.1.280's dialog, as drawn (spaces are cursor moves).
    private let dialog = """
    Quicksafetycheck:Isthisaprojectyoucreatedoroneyoutrust?
    ❯No,exit
    Yes,Itrustthisfolder
    Entertoconfirm·Esctocancel
    """

    func testTheTrustDialogIsAnsweredYesAndOnlyYes() {
        // The default is "No, exit": move down first, never Enter there.
        XCTAssertEqual(ClaudeCodeRenewal.trustKeys(screen: dialog), "\u{1b}[B")
        // Redrawn with the marker on Yes.
        XCTAssertEqual(ClaudeCodeRenewal.trustKeys(screen: dialog + "\n No, exit❯Yes, I trust this folder"), "\r")
        // The main screen's own prompt is not the dialog.
        XCTAssertNil(ClaudeCodeRenewal.trustKeys(screen: "❯ Try \"how does <filepath> work?\""))
    }

    func testEscapeSequencesAreReadThrough() {
        let raw = "\u{1b}[2K\u{1b}[1GYes,\u{1b}[1CI\u{1b}[1Ctrust\u{1b}]0;title\u{07}\u{1b}[?25l this folder\u{1b}(B"
        XCTAssertEqual(ClaudeCodeRenewal.plainText(raw), "Yes,Itrust this folder")
        XCTAssertEqual(ClaudeCodeRenewal.normalized("Yes, I trust\nthis folder"), "yes,itrustthisfolder")
    }

    func testClaudeCodeIsFoundWhereItsInstallersPutIt() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertNil(ClaudeCodeRenewal.claudeBinary(home: home).flatMap { $0.path.hasPrefix(home.path) ? $0 : nil })
        let versions = home.appendingPathComponent(".local/share/claude/versions")
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        for version in ["2.1.9", "2.1.280"] {
            let file = versions.appendingPathComponent(version)
            FileManager.default.createFile(atPath: file.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        let found = try XCTUnwrap(ClaudeCodeRenewal.claudeBinary(home: home))
        // The launcher wins where there is one; else the newest build.
        if !found.path.hasPrefix(home.path) { return }
        XCTAssertEqual(found.lastPathComponent, "2.1.280")
    }

    func testALaunchIsMadeAtMostEveryHalfHour() async {
        UserDefaults.standard.removeObject(forKey: ClaudeCodeRenewal.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ClaudeCodeRenewal.defaultsKey) }
        let gate = ClaudeCodeRenewal.Gate()
        let now = Date()
        let first = await gate.run(now: now) { .failed("signed out") }
        XCTAssertEqual(first, .failed("signed out"))
        XCTAssertEqual(ClaudeCodeRenewal.lastAttempt?.outcome, "failed(\"signed out\")")
        let soon = await gate.run(now: now.addingTimeInterval(600)) { .renewed }
        XCTAssertEqual(soon, .coolingDown)
        let later = await gate.run(now: now.addingTimeInterval(1_900)) { .renewed }
        XCTAssertEqual(later, .renewed)
    }

    func testARunOutSignInSaysRunningClaudeCodeIsEnough() {
        XCTAssertTrue(ClaudeProvider.expiredMessage(nil).contains("Claude Code"))
        XCTAssertNotEqual(ClaudeProvider.expiredMessage(.noClaudeCode), ClaudeProvider.expiredMessage(nil))
        XCTAssertEqual(ClaudeProvider.expiredMessage(.coolingDown), ClaudeProvider.expiredMessage(.failed("x")))
    }
}
