import CommonCrypto
import XCTest
@testable import QuotaCore

/// Cursor.app's sign-in in `state.vscdb`: in the clear before Cursor 3.27,
/// sealed with Electron `safeStorage` from 3.27 on, behind the keychain button.
final class CursorAppSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        LocalCredentials.resetCursorKeyMemo()
    }

    private let password = "synthetic-cursor-safe-storage-password"

    private func jwt(sub: String) -> String {
        let payload = Data(#"{"sub":"\#(sub)","exp":4102444800}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).c2ln"
    }

    /// What Cursor 3.27 writes: the prefix, then base64 of "v10" and
    /// AES-128-CBC under the PBKDF2 key, IV sixteen spaces.
    private func seal(_ plain: String) throws -> String {
        let key = try XCTUnwrap(QoderApp.deriveKey(password: Data(password.utf8)))
        let input = Data(plain.utf8)
        let iv = [UInt8](repeating: 0x20, count: 16)
        var out = Data(count: input.count + 16)
        var written = 0
        let capacity = out.count
        let status = out.withUnsafeMutableBytes { outBytes in
            input.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count, iv, inBytes.baseAddress, input.count,
                            outBytes.baseAddress, capacity, &written)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        return LocalCredentials.cursorSealedPrefix + (Data("v10".utf8) + out.prefix(written)).base64EncodedString()
    }

    private func keychain(_ answer: QoderApp.KeychainRead) -> (String, Bool) -> QoderApp.KeychainRead {
        { service, _ in
            XCTAssertEqual(service, "Cursor Safe Storage")
            return answer
        }
    }

    func testAPlainTokenIsReadWithoutTheKeychain() {
        let lookup = LocalCredentials.cursorLookup(
            interactive: false,
            stored: (jwt(sub: "auth0|user_1"), "pat@example.com"),
            read: { _, _ in
                XCTFail("a plain token must not touch the keychain")
                return .missing
            })
        XCTAssertEqual(lookup.state, .available)
        XCTAssertEqual(lookup.session?.subject, "auth0|user_1")
        XCTAssertEqual(lookup.session?.email, "pat@example.com")
    }

    func testASealedTokenOpensWithCursorsKey() throws {
        let token = jwt(sub: "auth0|user_2")
        let lookup = LocalCredentials.cursorLookup(
            interactive: false,
            stored: (try seal(token), try seal("pat@example.com")),
            read: keychain(.password(Data(password.utf8))))
        XCTAssertEqual(lookup.state, .available)
        XCTAssertEqual(lookup.session?.subject, "auth0|user_2")
        XCTAssertEqual(lookup.session?.email, "pat@example.com")
        XCTAssertEqual(lookup.session?.sessionCookie, "auth0|user_2::\(token)")
    }

    func testASealedTokenWaitsForTheButtonWhenTheKeychainWouldAsk() throws {
        let lookup = LocalCredentials.cursorLookup(
            interactive: false,
            stored: (try seal(jwt(sub: "auth0|user_3")), nil),
            read: keychain(.refused))
        XCTAssertEqual(lookup.state, .needsAuthorization)
        XCTAssertNil(lookup.session)
    }

    func testTheWrongKeyFailsClosed() throws {
        let lookup = LocalCredentials.cursorLookup(
            interactive: false,
            stored: (try seal(jwt(sub: "auth0|user_4")), nil),
            read: keychain(.password(Data("not-cursors-password".utf8))))
        XCTAssertEqual(lookup.state, .missing)
        XCTAssertNil(lookup.session)
    }

    func testAMalformedSealedValueIsNotASession() {
        for token in [LocalCredentials.cursorSealedPrefix + "!", LocalCredentials.cursorSealedPrefix + "AAAA"] {
            let lookup = LocalCredentials.cursorLookup(
                interactive: false,
                stored: (token, nil),
                read: keychain(.password(Data(password.utf8))))
            XCTAssertEqual(lookup.state, .missing, token)
        }
    }
}
