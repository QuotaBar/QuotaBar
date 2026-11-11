import XCTest
@testable import QuotaCore
import QuotaModel

/// Qoder's app sign-in: the safeStorage round trip, the token/account reader,
/// and the center.qoder.sh bearer parser. The access token is a plain bearer
/// for center.qoder.sh, so there is no request signing to pin.
final class QoderAppTests: XCTestCase {
    private func json(_ text: String) -> Data { Data(text.utf8) }

    // MARK: safeStorage

    func testSafeStorageRoundTrip() throws {
        // A v10 blob sealed with a derived key opens back to the same bytes.
        let key = try XCTUnwrap(QoderApp.deriveKey(password: Data("a-keychain-password".utf8)))
        let record = #"{"token":"tok","user":{"id":"u1","name":"Pat","email":"pat@example.com"}}"#
        let sealed = try XCTUnwrap(aesEncrypt(Data(record.utf8), key: key))
        let opened = try XCTUnwrap(QoderApp.decrypt(Data("v10".utf8) + sealed, key: key))
        XCTAssertEqual(String(data: opened, encoding: .utf8), record)
    }

    func testDecryptRejectsNonV10() {
        let key = QoderApp.deriveKey(password: Data("x".utf8))!
        XCTAssertNil(QoderApp.decrypt(Data("v11abcdef".utf8), key: key))
    }

    /// AES-128-CBC (IV = sixteen spaces) to build a v10 fixture, mirroring the
    /// scheme `QoderApp.decrypt` opens.
    private func aesEncrypt(_ data: Data, key: Data) -> Data? {
        import_CommonCrypto_encrypt(data, key: key)
    }

    // MARK: Token + account reader

    func testParseReadsTokenAndAccount() throws {
        let data = json(#"{"schemaVersion":1,"token":"access-abc","refreshToken":"r","user":{"id":"019f","name":"西风","email":"pat@example.com","phone":null}}"#)
        let signIn = try XCTUnwrap(QoderApp.parse(data))
        XCTAssertEqual(signIn.token, "access-abc")
        XCTAssertEqual(signIn.accountId, "019f")
        XCTAssertEqual(signIn.name, "西风")
        XCTAssertEqual(signIn.email, "pat@example.com")
    }

    func testParseNeedsAToken() {
        XCTAssertNil(QoderApp.parse(json(#"{"user":{"id":"1"}}"#)))
    }

    // MARK: "My usage" parser (recorded shape from a live Pro account)

    /// The real reply: plan credits, an add-on pack, and two resource packages
    /// (one SOTA, one unnamed) — the rows Qoder's own panel shows.
    private let liveUsage = #"""
    {"displayMode":"qoder","qoderUsage":{"userId":"019f","userType":"personal_professional","usageType":"credits","totalUsagePercentage":0.01,"isQuotaExceeded":false,"expiresAt":1796054400000,
    "userQuota":{"total":2000,"used":0,"remaining":2000,"percentage":0,"unit":"credits"},
    "addOnQuota":{"total":1100,"used":39,"remaining":1061,"percentage":0.04,"unit":"credits"},
    "dedicatedResourcePackages":[
      {"id":"a","name":"act-1","total":4096,"used":0,"remaining":4096,"unit":"credits","expiresAt":1793375939000,"available":true,"status":"QUOTA_DETAIL_STATUS_ACTIVE","displayLabels":[{"dimension":"title","value":"sota model series","valueI18n":{"en-US":"SOTA Exclusive Credits","zh-CN":"SOTA 专属积分"}}]},
      {"id":"b","name":"act-2","total":1024,"used":0,"remaining":1024,"unit":"credits","expiresAt":1793462339000,"available":true}
    ]}}
    """#

    func testParseAppReadsEveryBucketLikeThePanel() throws {
        let plan = json(#"{"user_type":"personal_professional","plan_tier_name":"Pro","end_date":1796054400000}"#)
        let snapshot = try QoderProvider.parseApp(usage: json(liveUsage), plan: plan, account: "pat@example.com")
        XCTAssertEqual(snapshot.planName, "Pro")
        XCTAssertEqual(snapshot.account, "pat@example.com")
        // Plan credits, add-on pack, SOTA, and the unnamed pack.
        XCTAssertEqual(snapshot.windows.count, 4)
        XCTAssertEqual(snapshot.windows[0].title, L10n.t("Plan Credits", "套餐内 Credits"))
        XCTAssertEqual(snapshot.windows[0].usedPercent, 0)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_796_054_400))
        XCTAssertEqual(snapshot.windows[1].title, L10n.t("Resource pack", "资源包"))
        XCTAssertEqual(snapshot.windows[1].detail, L10n.t("39 / 1100 credits", "39 / 1100 点"))
        XCTAssertEqual(snapshot.windows[1].usedPercent ?? 0, 39.0 / 1100 * 100, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[2].title, L10n.t("SOTA Exclusive Credits", "SOTA 专属积分"))
        XCTAssertEqual(snapshot.windows[2].resetsAt, Date(timeIntervalSince1970: 1_793_375_939))
    }

    func testParseAppSkipsUnavailablePackages() throws {
        let usage = json(#"{"qoderUsage":{"userQuota":{"total":2000,"used":0},"dedicatedResourcePackages":[{"name":"gone","total":500,"used":0,"available":false}]}}"#)
        let snapshot = try QoderProvider.parseApp(usage: usage, plan: nil)
        XCTAssertEqual(snapshot.windows.count, 1)  // only plan credits; the unavailable pack is dropped
    }

    func testParseAppUnmeteredFallsBackToPlanRow() throws {
        let usage = json(#"{"qoderUsage":{"userType":"personal_professional","isQuotaExceeded":false,"expiresAt":1796054400000}}"#)
        let plan = json(#"{"plan_tier_name":"Pro"}"#)
        let snapshot = try QoderProvider.parseApp(usage: usage, plan: plan)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].title, "Pro")
        XCTAssertNil(snapshot.windows[0].usedPercent)
    }

    func testParseAppPlanNameFallsBackToUserType() throws {
        let usage = json(#"{"qoderUsage":{"userType":"personal_professional","isQuotaExceeded":false}}"#)
        let snapshot = try QoderProvider.parseApp(usage: usage, plan: nil)
        XCTAssertEqual(snapshot.planName, "Personal Professional")
    }
}

// MARK: - Test helper: AES-128-CBC encrypt with a sixteen-space IV

import CommonCrypto

private func import_CommonCrypto_encrypt(_ data: Data, key: Data) -> Data? {
    let iv = [UInt8](repeating: 0x20, count: 16)
    var out = Data(count: data.count + 16)
    var written = 0
    let capacity = out.count
    let status = out.withUnsafeMutableBytes { ob in
        data.withUnsafeBytes { ib in
            key.withUnsafeBytes { kb in
                CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        kb.baseAddress, key.count, iv, ib.baseAddress, data.count, ob.baseAddress, capacity, &written)
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return out.prefix(written)
}
