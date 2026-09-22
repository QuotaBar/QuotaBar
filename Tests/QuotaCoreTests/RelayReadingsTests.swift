import CryptoKit
import XCTest
import QuotaModel
import QuotaRelay

/// A Mac's readings through quota.run, as the phone opens them.
final class RelayReadingsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private var readings: CloudReadings {
        CloudReadings(
            deviceID: "icloud-mac", deviceName: "Studio", appVersion: "0.6.0", language: "zh", updatedAt: t0,
            providers: [CloudReadings.Entry(
                id: "codex",
                snapshot: UsageSnapshot(planName: "Pro", windows: [UsageWindow(title: "5h", usedPercent: 42)], fetchedAt: t0),
                error: nil)])
    }

    /// What `GET /sync/readings` lists for one Mac.
    private func mac(id: String = "mac-1", grant: Data?, blob: Data?) throws -> RelayClient.Mac {
        var json: [String: Any] = ["deviceId": id, "name": "Studio"]
        if let grant { json["grant"] = Base64URL.encode(grant) }
        if let blob { json["blob"] = Base64URL.encode(blob) }
        return try JSONDecoder().decode(RelayClient.Mac.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testAnAllowedPhoneReadsWhatTheMacSent() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let key = SyncCrypto.newKey()
        let blob = try RelayReadings.seal(readings, key: key, macID: "mac-1")
        let grant = try SyncCrypto.wrap(key, for: phone.publicKey, macID: "mac-1", phoneID: "phone-1")
        guard case let .readings(opened) = RelayReadings.open(
            try mac(grant: grant, blob: blob), agreementKey: phone, phoneID: "phone-1")
        else { return XCTFail("did not open") }
        XCTAssertEqual(opened.deviceName, "Studio")
        XCTAssertEqual(opened.providers.first?.snapshot?.windows.first?.usedPercent, 42)
    }

    func testAMacThatHasNotAllowedThePhoneIsWaiting() throws {
        let blob = try RelayReadings.seal(readings, key: SyncCrypto.newKey(), macID: "mac-1")
        guard case .waiting = RelayReadings.open(
            try mac(grant: nil, blob: blob), agreementKey: P256.KeyAgreement.PrivateKey(), phoneID: "p")
        else { return XCTFail("expected waiting") }
    }

    func testAllowedButNothingSentIsEmpty() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let grant = try SyncCrypto.wrap(SyncCrypto.newKey(), for: phone.publicKey, macID: "mac-1", phoneID: "p")
        guard case .empty = RelayReadings.open(try mac(grant: grant, blob: nil), agreementKey: phone, phoneID: "p")
        else { return XCTFail("expected empty") }
    }

    /// The Mac changed its key after revoking another phone, and this
    /// phone's grant is from before: it does not open, and says so.
    func testAStaleGrantIsUnreadableNotACrash() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let grant = try SyncCrypto.wrap(SyncCrypto.newKey(), for: phone.publicKey, macID: "mac-1", phoneID: "p")
        let blob = try RelayReadings.seal(readings, key: SyncCrypto.newKey(), macID: "mac-1")
        guard case .unreadable = RelayReadings.open(try mac(grant: grant, blob: blob), agreementKey: phone, phoneID: "p")
        else { return XCTFail("expected unreadable") }
    }

    /// Both screens show the same six digits for the same key, and a
    /// different key gives different ones.
    func testTheSafetyCodeIsSixDigitsFromTheKey() {
        let key = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let code = SyncCrypto.safetyCode(for: key)
        XCTAssertEqual(code, SyncCrypto.safetyCode(for: key))
        XCTAssertNotNil(code.range(of: #"^\d{3} \d{3}$"#, options: .regularExpression))
        XCTAssertNotEqual(code, SyncCrypto.safetyCode(for: P256.KeyAgreement.PrivateKey().publicKey.x963Representation))
    }
}
