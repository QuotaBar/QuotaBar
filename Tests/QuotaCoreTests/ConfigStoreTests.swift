import XCTest
@testable import QuotaCore

final class ConfigStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-config-\(UUID().uuidString)")
            .appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func write(_ json: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try json.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func readBack() throws -> [String: Any] {
        let data = try Data(contentsOf: fileURL)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Keychain migration

    /// The shape older QuotaBar builds actually wrote: `Codable` flattens a
    /// dictionary keyed by a String-raw-value enum into an array.
    func testFlatArrayCredentialsAreMovedIntoTheKeychain() throws {
        try write("""
        {"enabled":["cursor"],"refreshMinutes":5,"menuBarStyle":"bar","presentation":"menuBar",
         "credentials":["cursor","session-abc","zai","key-xyz"]}
        """)
        let keychain = MemoryCredentialStorage()

        let store = ConfigStore(fileURL: fileURL, credentials: keychain)

        XCTAssertEqual(keychain.read(account: "cursor"), "session-abc")
        XCTAssertEqual(keychain.read(account: "zai"), "key-xyz")
        XCTAssertEqual(store.credential(for: .cursor), "session-abc")
    }

    /// The shape a hand-edited file is likely to use.
    func testObjectCredentialsAreMovedIntoTheKeychain() throws {
        try write("""
        {"enabled":["cursor"],"credentials":{"cursor":"session-abc","zai":"key-xyz"}}
        """)
        let keychain = MemoryCredentialStorage()

        _ = ConfigStore(fileURL: fileURL, credentials: keychain)

        XCTAssertEqual(keychain.read(account: "cursor"), "session-abc")
        XCTAssertEqual(keychain.read(account: "zai"), "key-xyz")
    }

    func testEmptyLegacyArrayIsHarmless() throws {
        // What a current install with no manual credentials looks like.
        try write("""
        {"enabled":["codex","claude"],"credentials":[],"refreshMinutes":5}
        """)
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        XCTAssertEqual(store.enabledProviders, [.codex, .claude])
        XCTAssertNil(store.credential(for: .cursor))
    }

    func testLeftoverEmptyCredentialsKeyIsDroppedOnLoad() throws {
        try write("""
        {"enabled":["codex"],"credentials":[],"refreshMinutes":5}
        """)

        _ = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())

        let onDisk = try readBack()
        XCTAssertNil(onDisk["credentials"])
        XCTAssertEqual(onDisk["enabled"] as? [String], ["codex"])
        XCTAssertEqual(onDisk["refreshMinutes"] as? Int, 5)
    }

    func testFileWithoutCredentialsKeyIsNotRewritten() throws {
        try write("""
        {"enabled":["codex"],"refreshMinutes":5,"menuBarStyle":"bar","presentation":"menuBar",\
         "alerts":{"enabled":true,"warning":80,"critical":95},"language":"system"}
        """)
        let before = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date

        _ = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())

        let after = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after, "a clean file should not be rewritten on every launch")
    }

    func testUnknownProviderInLegacyCredentialsIsSkipped() throws {
        try write("""
        {"enabled":[],"credentials":["retired-provider","x","zai","key-xyz"]}
        """)
        let keychain = MemoryCredentialStorage()
        _ = ConfigStore(fileURL: fileURL, credentials: keychain)
        XCTAssertEqual(keychain.read(account: "zai"), "key-xyz")
    }

    func testMigrationErasesPlaintextFromDisk() throws {
        try write("""
        {"enabled":["cursor"],"credentials":["cursor","session-abc"]}
        """)

        _ = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())

        let onDisk = try readBack()
        XCTAssertNil(onDisk["credentials"], "the secret must not survive on disk")
        XCTAssertEqual(onDisk["enabled"] as? [String], ["cursor"])
    }

    func testCredentialsAreNeverWrittenToDisk() throws {
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())

        store.setCredential("brand-new-secret", for: .kimi)
        store.refreshMinutes = 15

        let raw = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("brand-new-secret"))
        XCTAssertTrue(raw.contains("\"refreshMinutes\" : 15"))
    }

    func testFileIsOwnerOnly() throws {
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        store.refreshMinutes = 2

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }

    // MARK: Credentials

    func testBlankCredentialClearsTheEntry() {
        let keychain = MemoryCredentialStorage(["kimi": "old"])
        let store = ConfigStore(fileURL: fileURL, credentials: keychain)

        store.setCredential("   ", for: .kimi)

        XCTAssertNil(store.credential(for: .kimi))
        XCTAssertNil(keychain.read(account: "kimi"))
    }

    func testCredentialIsTrimmed() {
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        store.setCredential("  token-with-spaces \n", for: .zai)
        XCTAssertEqual(store.credential(for: .zai), "token-with-spaces")
    }

    // MARK: Preferences

    func testRoundTripsPreferences() throws {
        let keychain = MemoryCredentialStorage()
        let first = ConfigStore(fileURL: fileURL, credentials: keychain)
        first.refreshMinutes = 15
        first.menuBarStyle = .ring
        first.presentation = .island
        first.language = .zhHans
        first.setEnabled(.gemini, true)

        let second = ConfigStore(fileURL: fileURL, credentials: keychain)

        XCTAssertEqual(second.refreshMinutes, 15)
        XCTAssertEqual(second.menuBarStyle, .ring)
        XCTAssertEqual(second.presentation, .island)
        XCTAssertEqual(second.language, .zhHans)
        XCTAssertTrue(second.isEnabled(.gemini))
        L10n.override = .system
    }

    func testRefreshIntervalCannotBeZero() {
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        store.refreshMinutes = 0
        XCTAssertEqual(store.refreshMinutes, 1)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        try write("{ not valid json")
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        XCTAssertEqual(store.refreshMinutes, 5)
        XCTAssertEqual(store.enabledProviders, [.codex, .claude])
    }

    func testUnknownKeysInFileAreTolerated() throws {
        try write("""
        {"enabled":["claude"],"refreshMinutes":2,"somethingFromAFutureVersion":true}
        """)
        let store = ConfigStore(fileURL: fileURL, credentials: MemoryCredentialStorage())
        XCTAssertEqual(store.refreshMinutes, 2)
        XCTAssertEqual(store.enabledProviders, [.claude])
    }
}

final class AlertSettingsTests: XCTestCase {
    func testCriticalIsPulledUpToWarning() {
        let settings = AlertSettings(enabled: true, warning: 90, critical: 70).normalized()
        XCTAssertEqual(settings.warning, 90)
        XCTAssertEqual(settings.critical, 90)
    }

    func testInvertedThresholdsStillAllowACriticalLevel() {
        // Before normalization a warning above critical made `.critical`
        // unreachable — every reading matched the warning band first.
        let settings = AlertSettings(enabled: true, warning: 90, critical: 70)
        XCTAssertEqual(settings.level(for: 95), .critical)
        XCTAssertEqual(settings.level(for: 91), .critical)
        XCTAssertEqual(settings.level(for: 80), .none)
    }

    func testNormalLevels() {
        let settings = AlertSettings(enabled: true, warning: 80, critical: 95)
        XCTAssertEqual(settings.level(for: 10), .none)
        XCTAssertEqual(settings.level(for: 80), .warning)
        XCTAssertEqual(settings.level(for: 94.9), .warning)
        XCTAssertEqual(settings.level(for: 95), .critical)
    }

    func testDisabledAlwaysReportsNone() {
        let settings = AlertSettings(enabled: false, warning: 10, critical: 20)
        XCTAssertEqual(settings.level(for: 100), .none)
    }

    func testThresholdsAreClampedToPercentRange() {
        let settings = AlertSettings(enabled: true, warning: -5, critical: 300).normalized()
        XCTAssertEqual(settings.warning, 1)
        XCTAssertEqual(settings.critical, 100)
    }
}

final class UsageHistoryStoreTests: XCTestCase {
    private var fileURL: URL!

    override func setUpWithError() throws {
        fileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("quotabar-history-\(UUID().uuidString)")
            .appendingPathComponent("history.json")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    func testRecordsAndReadsBack() {
        let store = UsageHistoryStore(fileURL: fileURL)
        store.record(.codex, percent: 10, at: Date(timeIntervalSince1970: 1))
        store.record(.codex, percent: 20, at: Date(timeIntervalSince1970: 2))

        XCTAssertEqual(store.readings(for: .codex).map(\.percent), [10, 20])
        XCTAssertTrue(store.readings(for: .claude).isEmpty)
    }

    func testPersistsAcrossInstances() {
        UsageHistoryStore(fileURL: fileURL).record(.claude, percent: 42)
        XCTAssertEqual(UsageHistoryStore(fileURL: fileURL).readings(for: .claude).map(\.percent), [42])
    }

    func testWritesAReadableObject() throws {
        UsageHistoryStore(fileURL: fileURL).record(.codex, percent: 5)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
        XCTAssertTrue(root is [String: Any], "history should be a JSON object, not a flat array")
    }

    func testReadsTheLegacyFlatArrayFormat() throws {
        // What earlier builds wrote: Codable's array encoding for a dictionary
        // keyed by a String-raw-value enum.
        try """
        ["claude",[{"t":1787249642.39,"percent":72}],"codex",[{"t":1787249642.39,"percent":10}]]
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = UsageHistoryStore(fileURL: fileURL)

        XCTAssertEqual(store.readings(for: .claude).map(\.percent), [72])
        XCTAssertEqual(store.readings(for: .codex).map(\.percent), [10])
    }

    func testLegacyDataIsUpgradedOnNextWrite() throws {
        try """
        ["claude",[{"t":1.0,"percent":72}]]
        """.write(to: fileURL, atomically: true, encoding: .utf8)

        let store = UsageHistoryStore(fileURL: fileURL)
        store.record(.claude, percent: 73)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
        XCTAssertTrue(root is [String: Any])
        XCTAssertEqual(UsageHistoryStore(fileURL: fileURL).readings(for: .claude).map(\.percent), [72, 73])
    }

    func testReadingsAreCappedToTheRequestedLimit() {
        let store = UsageHistoryStore(fileURL: fileURL)
        for index in 0..<20 {
            store.record(.zai, percent: Double(index), at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(store.readings(for: .zai, limit: 5).map(\.percent), [15, 16, 17, 18, 19])
    }

    func testClearForgetsAProvider() {
        let store = UsageHistoryStore(fileURL: fileURL)
        store.record(.grok, percent: 1)
        store.clear(.grok)
        XCTAssertTrue(store.readings(for: .grok).isEmpty)
    }

    func testCorruptFileIsIgnored() throws {
        try "{{{ not json".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(UsageHistoryStore(fileURL: fileURL).readings(for: .codex).isEmpty)
    }
}
