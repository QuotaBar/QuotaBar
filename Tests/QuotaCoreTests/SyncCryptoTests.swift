import CryptoKit
import XCTest
import QuotaRelay

/// The relay's promise is that quota.run cannot read what it carries, and
/// cannot pass one device's secrets off as another's. These pin both.
final class SyncCryptoTests: XCTestCase {
    private let readings = Data(#"{"providers":[{"id":"claude"}]}"#.utf8)

    func testReadingsOpenWithTheKeyTheyWereSealedWith() throws {
        let key = SyncCrypto.newKey()
        let blob = try SyncCrypto.seal(readings, key: key, macID: "mac-1")
        XCTAssertNotEqual(blob, readings)
        XCTAssertEqual(try SyncCrypto.open(blob, key: key, macID: "mac-1"), readings)
        XCTAssertThrowsError(try SyncCrypto.open(blob, key: SyncCrypto.newKey(), macID: "mac-1"))
    }

    /// A blob served under another Mac's row does not open as that Mac's.
    func testReadingsAreBoundToTheirMac() throws {
        let key = SyncCrypto.newKey()
        let blob = try SyncCrypto.seal(readings, key: key, macID: "mac-1")
        XCTAssertThrowsError(try SyncCrypto.open(blob, key: key, macID: "mac-2"))
    }

    func testTheKeyReachesThePhoneItWasSealedFor() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let key = SyncCrypto.newKey()
        let wrapped = try SyncCrypto.wrap(key, for: phone.publicKey, macID: "mac-1", phoneID: "phone-1")
        let opened = try SyncCrypto.unwrap(wrapped, with: phone, macID: "mac-1", phoneID: "phone-1")
        XCTAssertEqual(opened.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        // The raw key is nowhere in what the server stores.
        XCTAssertNil(wrapped.range(of: key.withUnsafeBytes { Data($0) }))
    }

    func testAnotherPhoneCannotOpenIt() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let wrapped = try SyncCrypto.wrap(SyncCrypto.newKey(), for: phone.publicKey, macID: "m", phoneID: "p")
        XCTAssertThrowsError(try SyncCrypto.unwrap(wrapped, with: P256.KeyAgreement.PrivateKey(), macID: "m", phoneID: "p"))
    }

    /// A grant moved to another Mac's row, or to another phone, is refused.
    func testTheKeyIsBoundToItsMacAndPhone() throws {
        let phone = P256.KeyAgreement.PrivateKey()
        let wrapped = try SyncCrypto.wrap(SyncCrypto.newKey(), for: phone.publicKey, macID: "mac-1", phoneID: "phone-1")
        XCTAssertThrowsError(try SyncCrypto.unwrap(wrapped, with: phone, macID: "mac-2", phoneID: "phone-1"))
        XCTAssertThrowsError(try SyncCrypto.unwrap(wrapped, with: phone, macID: "mac-1", phoneID: "phone-2"))
    }

    func testMalformedGrantsAreRefusedNotCrashedOn() {
        let phone = P256.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try SyncCrypto.unwrap(Data(), with: phone, macID: "m", phoneID: "p"))
        XCTAssertThrowsError(try SyncCrypto.unwrap(Data([9, 0, 1, 2]), with: phone, macID: "m", phoneID: "p")) { error in
            XCTAssertEqual(error as? SyncCrypto.Failure, .unsupportedVersion)
        }
        XCTAssertThrowsError(try SyncCrypto.unwrap(Data([1, 0xFF, 0xFF, 1]), with: phone, macID: "m", phoneID: "p"))
    }

    /// The canonical string the server rebuilds, byte for byte.
    func testCanonicalStringMatchesTheContract() {
        let text = RunCanonical.string(method: "put", path: "/api/v1/sync/readings", timestamp: 1_790_000_000, nonce: "n", body: Data("{}".utf8))
        XCTAssertEqual(text, "quota-run-v1\nPUT\n/api/v1/sync/readings\n1790000000\nn\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
    }
}
