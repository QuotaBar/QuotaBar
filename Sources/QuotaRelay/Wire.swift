import CryptoKit
import Foundation

// MARK: - The Quota Run wire format, shared by the Mac and the iPhone
//
// Contract: docs/quota-run.md in the quota.run repository. Every signed
// request, from either device, signs the same canonical string with a P-256
// key that never leaves the device.

/// base64url without padding — every key, nonce and signature on the wire.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func decode(_ string: String) -> Data? {
        var base = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 { base += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: base)
    }
}

/// The device's signing key, wherever it lives. The Secure Enclave key and the
/// software fallback both reach the client through this, and the tests sign
/// with a software key.
public protocol RunSigner: Sendable {
    /// X9.63 uncompressed point, 65 bytes.
    var publicKeyX963: Data { get }
    /// ECDSA P-256 over SHA-256 of `data`, DER encoded.
    func signature(for data: Data) throws -> Data
}

public struct SoftwareRunSigner: RunSigner {
    public let key: P256.Signing.PrivateKey

    public init(key: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.key = key
    }

    public var publicKeyX963: Data { key.publicKey.x963Representation }

    public func signature(for data: Data) throws -> Data {
        try key.signature(for: data).derRepresentation
    }
}

/// The string every authenticated request signs.
public enum RunCanonical {
    public static let prefix = "quota-run-v1"

    /// Lower-case hex SHA-256 of the raw body; of the empty string without one.
    public static func bodyHash(_ body: Data?) -> String {
        SHA256.hash(data: body ?? Data()).map { String(format: "%02x", $0) }.joined()
    }

    public static func string(method: String, path: String, timestamp: Int, nonce: String, body: Data?) -> String {
        [prefix, method.uppercased(), path, String(timestamp), nonce, bodyHash(body)].joined(separator: "\n")
    }
}
