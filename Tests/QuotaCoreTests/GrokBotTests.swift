import CommonCrypto
import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Grok Bot's allowance goes on the card of whoever pays for it, and its
/// sign-in is read from Grok Bot's own store only when Cursor.app is not
/// signed in to the same account.
final class GrokBotTests: XCTestCase {
    override func setUp() {
        super.setUp()
        GrokBot.resetKeyMemo()
    }

    private func status(_ json: String) throws -> GrokBot.Status {
        try JSONDecoder().decode(GrokBot.Status.self, from: Data(json.utf8))
    }

    private let allowance = #""usagePercent":40,"hasNonZeroIncludedLimit":true,"nextResetTimestampUtc":"2026-09-30T00:00:00.000Z""#

    // MARK: Who pays

    func testTheBillingBrandSaysWhoPays() throws {
        XCTAssertEqual(try status(#"{"billingBrand":"SAND_BILLING_BRAND_CURSOR"}"#).billing, .cursor)
        XCTAssertEqual(try status(#"{"billingBrand":"SAND_BILLING_BRAND_GROK"}"#).billing, .grok)
        XCTAssertEqual(try status(#"{"billingBrand":"SAND_BILLING_BRAND_XAI"}"#).billing, .grok)
        // Said outright, the brand wins over the SuperGrok field.
        XCTAssertEqual(
            try status(#"{"billingBrand":"SAND_BILLING_BRAND_CURSOR","includedUsageSuperGrokPlan":"SuperGrok"}"#).billing,
            .cursor)
    }

    /// A Cursor-paid allowance on a Mac without a Cursor card — Cursor
    /// uninstalled, or turned off — goes on the Grok card, not nowhere.
    func testWithoutACursorCardTheCursorPaidRowComesToGrok() throws {
        let cursorPaid = try status(#"{"billingBrand":"SAND_BILLING_BRAND_CURSOR",\#(allowance)}"#)
        XCTAssertFalse(GrokBot.belongsOnGrokCard(cursorPaid, cursorCardShown: true))
        XCTAssertTrue(GrokBot.belongsOnGrokCard(cursorPaid, cursorCardShown: false))
        let grokPaid = try status(#"{"billingBrand":"SAND_BILLING_BRAND_GROK",\#(allowance)}"#)
        XCTAssertTrue(GrokBot.belongsOnGrokCard(grokPaid, cursorCardShown: true))
    }

    func testWithoutABrandALinkedSuperGrokPlanMeansGrok() throws {
        let linked = try status(#"{"includedUsageSuperGrokPlan":" SuperGrok Plus "}"#)
        XCTAssertEqual(linked.billing, .grok)
        XCTAssertEqual(linked.superGrokPlan, "SuperGrok Plus")
        XCTAssertEqual(try status(#"{"includedUsageSuperGrokPlan":""}"#).billing, .cursor)
        XCTAssertEqual(try status(#"{"billingBrand":"SAND_BILLING_BRAND_UNSPECIFIED"}"#).billing, .cursor)
        // What every account said before the field existed: Cursor's, as before.
        XCTAssertEqual(try status("{}").billing, .cursor)
    }

    // MARK: The Cursor card

    private let summary = Data("""
    {"membershipType":"pro","billingCycleEnd":"2026-10-01T00:00:00.000Z",
     "individualUsage":{"plan":{"totalPercentUsed":42,"apiPercentUsed":60,"limit":2000,"used":840}}}
    """.utf8)

    func testTheCursorCardKeepsTheRowCursorPaysFor() throws {
        let sand = Data(#"{\#(allowance),"billingBrand":"SAND_BILLING_BRAND_CURSOR","cursorPlanName":"Pro+"}"#.utf8)
        let snapshot = try CursorProvider.parse(summary, sand: sand)
        XCTAssertEqual(snapshot.windows.last?.title, "Grok Bot")
    }

    func testTheCursorCardLeavesTheSuperGrokRowToGrok() throws {
        let sand = Data(#"{\#(allowance),"billingBrand":"SAND_BILLING_BRAND_GROK"}"#.utf8)
        XCTAssertFalse(try CursorProvider.parse(summary, sand: sand).windows.contains { $0.title == "Grok Bot" })
        let linked = Data(#"{\#(allowance),"includedUsageSuperGrokPlan":"SuperGrok Heavy"}"#.utf8)
        XCTAssertFalse(try CursorProvider.parse(summary, sand: linked).windows.contains { $0.title == "Grok Bot" })
    }

    // MARK: The Grok card

    func testGrokBotAloneFillsTheCardWhenSuperGrokPays() throws {
        let window = try XCTUnwrap(GrokBot.window(status("{\(allowance)}")))
        let snapshot = try GrokProvider.botOnly(.row(window, plan: "SuperGrok Plus", account: "dev@example.com"))
        XCTAssertEqual(snapshot.planName, "SuperGrok Plus")
        XCTAssertEqual(snapshot.account, "dev@example.com")
        XCTAssertEqual(snapshot.windows.map(\.title), ["Grok Bot"])
        // The only row, so the card's figure follows it even though it is an extra.
        XCTAssertEqual(snapshot.headlinePercent, 40)
    }

    func testGrokBotAloneSaysWhereElseItIs() {
        XCTAssertThrowsError(try GrokProvider.botOnly(.onCursorCard)) { error in
            guard case let ProviderError.notConfigured(hint) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(hint, GrokBot.onCursorCardHint)
        }
        XCTAssertThrowsError(try GrokProvider.botOnly(.needsAuthorization)) { error in
            guard case ProviderError.needsAuthorization = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try GrokProvider.botOnly(.nothing)) { error in
            guard case ProviderError.notConfigured = error else { return XCTFail("\(error)") }
        }
    }

    /// No period and no figure: nothing the account is on. (A period with
    /// no figure is a SuperGrok week with nothing used yet — protobuf JSON
    /// leaves the zero out — and reads as 0%; see GrokTests.)
    func testAnXAIAccountWithoutAPlanIsSaidAsSuch() {
        let body = #"{"config":{"onDemandCap":{"val":0},"onDemandUsed":{"val":0},"isUnifiedBillingUser":true}}"#
        XCTAssertThrowsError(try GrokProvider.parse(Data(body.utf8))) { error in
            guard case ProviderError.noPlan = error else { return XCTFail("\(error)") }
        }
    }

    // MARK: Grok Bot's store

    private func jwt(sub: String) -> String {
        let payload = Data(#"{"sub":"\#(sub)","exp":4102444800}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2ln"
    }

    /// What Electron's `safeStorage.encryptString(...).toString("base64")` writes.
    private func seal(_ plain: String, password: String) throws -> String {
        let key = try XCTUnwrap(GrokBot.deriveKey(password: Data(password.utf8)))
        let input = Data(plain.utf8)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var written = 0
        let capacity = out.count
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let status = out.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, inBytes.baseAddress, input.count,
                        outBytes.baseAddress, capacity, &written)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return (Data("v10".utf8) + out.prefix(written)).base64EncodedString()
    }

    private func storeData(active: String, token: String, profile: String? = nil) -> Data {
        var entry = ["cursor-access-token": token, "cursor-refresh-token": token]
        if let profile { entry["cursor-account-profile"] = profile }
        let accounts = try! JSONSerialization.data(withJSONObject: ["active": active, "accounts": [active: entry]])
        let root: [String: Any] = [
            "cursor-machine-id": "djEw",
            "cursor-accounts": String(decoding: accounts, as: UTF8.self),
        ]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    func testAccountsAreKeyedByTheSha256OfTheSubject() {
        XCTAssertEqual(
            GrokBot.accountID(sub: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testTheSafeStorageSchemeRoundTrips() throws {
        let sealed = try seal("a token that spans more than one block", password: "keychain secret")
        let key = try XCTUnwrap(GrokBot.deriveKey(password: Data("keychain secret".utf8)))
        XCTAssertEqual(GrokBot.decrypt(sealed, key: key), "a token that spans more than one block")
        let wrong = try XCTUnwrap(GrokBot.deriveKey(password: Data("another".utf8)))
        XCTAssertNotEqual(GrokBot.decrypt(sealed, key: wrong), "a token that spans more than one block")
        XCTAssertNil(GrokBot.decrypt("bm90IHNlYWxlZA==", key: key))
    }

    func testStoredValuesComeThreeWays() {
        XCTAssertEqual(GrokBot.Store.plaintext("plaintext:v1:" + Data("tok".utf8).base64EncodedString()), "tok")
        XCTAssertNil(GrokBot.Store.plaintext("djEwAAAA"))
        let scope = String(repeating: "a", count: 64)
        XCTAssertEqual(GrokBot.Store.ciphertext("scoped:v1:\(scope):djEwAAAA"), "djEwAAAA")
        XCTAssertEqual(GrokBot.Store.ciphertext("djEwAAAA"), "djEwAAAA")
    }

    func testTheStoreReadsTheActiveAccount() throws {
        let store = try XCTUnwrap(GrokBot.Store(data: storeData(active: "abc", token: "djEwAAAA", profile: "djEwBBBB")))
        XCTAssertEqual(store.active, "abc")
        XCTAssertEqual(store.accessToken, "djEwAAAA")
        XCTAssertEqual(store.profile, "djEwBBBB")
        // Signed out: an account record with no active one, and nothing at the top.
        let signedOut = try JSONSerialization.data(withJSONObject: [
            "cursor-accounts": #"{"active":null,"accounts":{}}"#,
        ])
        XCTAssertNil(GrokBot.Store(data: signedOut))
        XCTAssertNil(GrokBot.Store(data: Data("not json".utf8)))
        // The older layout, one token at the top level.
        let older = try XCTUnwrap(GrokBot.Store(data: JSONSerialization.data(withJSONObject: ["cursor-access-token": "djEwCCCC"])))
        XCTAssertNil(older.active)
        XCTAssertEqual(older.accessToken, "djEwCCCC")
    }

    // MARK: Finding the sign-in

    func testCursorAppOnTheSameAccountIsUsedWithoutTheKeychain() throws {
        let editor = try XCTUnwrap(LocalCredentials.makeCursorSession(accessToken: jwt(sub: "auth0|user_1"), email: "me@example.com"))
        let store = GrokBot.Store(data: storeData(active: GrokBot.accountID(sub: "auth0|user_1"), token: "djEwAAAA"))
        let found = GrokBot.lookup(interactive: false, store: store, editor: editor) { _ in
            XCTFail("the keychain was read"); return .refused
        }
        XCTAssertEqual(found.state, .available)
        XCTAssertTrue(found.viaCursorApp)
        XCTAssertEqual(found.session?.email, "me@example.com")
    }

    func testAnotherAccountIsDecryptedWithTheKeychainKey() throws {
        let token = jwt(sub: "auth0|grok_only")
        let store = GrokBot.Store(data: storeData(
            active: GrokBot.accountID(sub: "auth0|grok_only"),
            token: "scoped:v1:\(String(repeating: "b", count: 64)):" + (try seal(token, password: "pw")),
            profile: try seal(#"{"email":"grok@example.com","name":"G"}"#, password: "pw")))
        let editor = LocalCredentials.makeCursorSession(accessToken: jwt(sub: "auth0|someone_else"), email: nil)
        let found = GrokBot.lookup(interactive: false, store: store, editor: editor) { _ in .password(Data("pw".utf8)) }
        XCTAssertEqual(found.state, .available)
        XCTAssertFalse(found.viaCursorApp)
        XCTAssertEqual(found.session?.subject, "auth0|grok_only")
        XCTAssertEqual(found.session?.email, "grok@example.com")
        XCTAssertTrue(found.session?.cookieHeader.hasPrefix("WorkosCursorSessionToken=auth0%7Cgrok%5Fonly%3A%3A") == true)
    }

    func testARefusalWaitsForTheButton() throws {
        let store = GrokBot.Store(data: storeData(active: "x", token: "djEwAAAA"))
        var reads: [Bool] = []
        let reader: (Bool) -> GrokBot.KeychainRead = { interactive in
            reads.append(interactive)
            return interactive ? .password(Data("pw".utf8)) : .refused
        }
        XCTAssertEqual(GrokBot.lookup(interactive: false, store: store, editor: nil, password: reader).state, .needsAuthorization)
        // A refresh a moment later does not knock again.
        XCTAssertEqual(GrokBot.lookup(interactive: false, store: store, editor: nil, password: reader).state, .needsAuthorization)
        XCTAssertEqual(reads, [false])
        // The button asks, and the key is kept: no further reads.
        _ = GrokBot.lookup(interactive: true, store: store, editor: nil, password: reader)
        _ = GrokBot.lookup(interactive: false, store: store, editor: nil, password: reader)
        XCTAssertEqual(reads, [false, true])
    }

    func testAPlaintextStoreNeedsNoKeychain() throws {
        let token = jwt(sub: "auth0|linux_like")
        let store = GrokBot.Store(data: storeData(active: "x", token: "plaintext:v1:" + Data(token.utf8).base64EncodedString()))
        let found = GrokBot.lookup(interactive: false, store: store, editor: nil) { _ in
            XCTFail("the keychain was read"); return .refused
        }
        XCTAssertEqual(found.state, .available)
        XCTAssertEqual(found.session?.subject, "auth0|linux_like")
    }

    func testNoStoreIsNoSignIn() {
        XCTAssertEqual(GrokBot.lookup(interactive: false, store: nil, editor: nil) { _ in .refused }.state, .missing)
        let store = GrokBot.Store(data: storeData(active: "x", token: "djEwAAAA"))
        XCTAssertEqual(GrokBot.lookup(interactive: false, store: store, editor: nil) { _ in .missing }.state, .missing)
    }
}
