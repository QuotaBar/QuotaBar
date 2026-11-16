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
        // 2.1.325 redraws only the marker after an arrow: once one went down
        // from "No, exit", that marker is on Yes.
        let redrawn = dialog + "\n \n❯\n\n\n\n❯\n "
        XCTAssertEqual(ClaudeCodeRenewal.trustKeys(screen: redrawn, movedDown: true), "\r")
        XCTAssertEqual(ClaudeCodeRenewal.trustKeys(screen: redrawn, movedDown: false), "\u{1b}[B")
        // Still drawn on No after the arrow: down again, never Enter.
        XCTAssertEqual(ClaudeCodeRenewal.trustKeys(screen: dialog, movedDown: true), "\u{1b}[B")
        // The main screen's own prompt is not the dialog.
        XCTAssertNil(ClaudeCodeRenewal.trustKeys(screen: "❯ Try \"how does <filepath> work?\""))
    }

    /// Claude Code 2.1.325's first-run onboarding, as drawn in a config dir
    /// signed in with `claude auth login`.
    func testFirstRunOnboardingIsStepPastAndNothingElse() {
        let theme = """
        WelcometoClaudeCodev2.1.325
        Let'sgetstarted.
        Choosethetextstylethatlooksbestwithyourterminal
        Tochangethislater,run/theme
        Auto(matchterminal)
        ❯✔Darkmode
        Lightmode
        """
        XCTAssertEqual(ClaudeCodeRenewal.onboardingKeys(screen: theme), "\r")
        XCTAssertTrue(ClaudeCodeRenewal.onboardingUp(screen: theme))
        // Letters lost to cursor moves, as read off the terminal.
        let notes = """
        Scurity noes:
        1. Claude can make misakes.
        Learn more:https://code.claude.com/docs/en/security
        Press Ener tocontinue…
        """
        XCTAssertEqual(ClaudeCodeRenewal.onboardingKeys(screen: notes), "\r")
        XCTAssertTrue(ClaudeCodeRenewal.onboardingUp(screen: "Press Ener tocontinue…"))
        // Still being drawn: nothing typed yet, nothing answered.
        let drawing = "WelcometoClaudeCodev2.1.325\nLet'sgetstarted."
        XCTAssertNil(ClaudeCodeRenewal.onboardingKeys(screen: drawing))
        XCTAssertTrue(ClaudeCodeRenewal.onboardingUp(screen: drawing))
        // A login method is never picked, and the main screen is left alone.
        XCTAssertNil(ClaudeCodeRenewal.onboardingKeys(screen: "Select login method:\n❯ 1. Claude account with subscription"))
        XCTAssertNil(ClaudeCodeRenewal.onboardingKeys(screen: dialog))
        XCTAssertFalse(ClaudeCodeRenewal.onboardingUp(screen: "❯ Try \"fix typecheck errors\""))
    }

    /// `QUOTABAR_CLAUDE_RENEWAL_SERVICE=<keychain item> swift test --filter
    /// testARealLaunchReachesStatus`: the whole launch against a real sign-in
    /// on this Mac — onboarding and trust answered, `/status` reached.
    func testARealLaunchReachesStatus() throws {
        guard let service = ProcessInfo.processInfo.environment["QUOTABAR_CLAUDE_RENEWAL_SERVICE"] else {
            throw XCTSkip("Set QUOTABAR_CLAUDE_RENEWAL_SERVICE to try a real launch.")
        }
        let binary = try XCTUnwrap(ClaudeCodeRenewal.claudeBinary())
        let configDir = service == LocalCredentials.claudeService ? nil : try XCTUnwrap(LocalCredentials.claudeConfigDir(service: service))
        let token = LocalCredentials.readClaudeNow(service: service).token
        let outcome = ClaudeCodeRenewal.Session(binary: binary, service: service, configDir: configDir).run(replacing: token, force: true)
        XCTAssertTrue(outcome == .renewed || outcome == .notNeeded, "\(outcome)")
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
        let gate = CLIRenewal.Gate(key: ClaudeCodeRenewal.defaultsKey)
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
        XCTAssertNotEqual(ClaudeProvider.expiredMessage(.noCLI), ClaudeProvider.expiredMessage(nil))
        XCTAssertEqual(ClaudeProvider.expiredMessage(.coolingDown), ClaudeProvider.expiredMessage(.failed("x")))
    }
}
