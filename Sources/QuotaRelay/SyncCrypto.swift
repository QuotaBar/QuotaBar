import CryptoKit
import Foundation

// MARK: - End-to-end encryption for the readings relay

/// What keeps quota.run from reading what it relays. Each Mac has its own
/// sync key and seals its readings with it; a phone gets that key only when
/// the owner allows it on the Mac, which seals the key to the phone's own
/// public key (HPKE). The server holds ciphertext, sealed keys and public
/// keys — nothing that opens either.
///
/// Both seals are bound to where they belong, so a server that shuffled
/// rows could not make a phone accept one Mac's blob as another's, or a key
/// sealed for one phone as meant for another.
public enum SyncCrypto {
    public enum Failure: Error, Equatable {
        case malformed
        case unsupportedVersion
    }

    public static let keyByteCount = 32

    public static func newKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: Readings

    /// AES-GCM, nonce and tag included. `macID` is the Mac's quota.run device
    /// id, authenticated alongside.
    public static func seal(_ readings: Data, key: SymmetricKey, macID: String) throws -> Data {
        guard let sealed = try AES.GCM.seal(readings, using: key, authenticating: readingsContext(macID)).combined else {
            throw Failure.malformed
        }
        return sealed
    }

    public static func open(_ blob: Data, key: SymmetricKey, macID: String) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: key, authenticating: readingsContext(macID))
    }

    private static func readingsContext(_ macID: String) -> Data {
        Data("quotabar-readings-v1\n\(macID)".utf8)
    }

    // MARK: The key, to a phone

    private static let suite = HPKE.Ciphersuite.P256_SHA256_AES_GCM_256
    private static let wrapVersion: UInt8 = 1

    /// The Mac's sync key sealed to one phone: `[version][enc length][enc][ciphertext]`.
    public static func wrap(
        _ key: SymmetricKey, for phone: P256.KeyAgreement.PublicKey, macID: String, phoneID: String) throws -> Data
    {
        var sender = try HPKE.Sender(recipientKey: phone, ciphersuite: suite, info: wrapContext(macID, phoneID))
        let sealed = try sender.seal(key.withUnsafeBytes { Data($0) })
        let enc = sender.encapsulatedKey
        var out = Data([wrapVersion, UInt8(enc.count >> 8), UInt8(enc.count & 0xFF)])
        out.append(enc)
        out.append(sealed)
        return out
    }

    public static func unwrap(
        _ wrapped: Data, with phone: P256.KeyAgreement.PrivateKey, macID: String, phoneID: String) throws -> SymmetricKey
    {
        let bytes = [UInt8](wrapped)
        guard bytes.count > 3 else { throw Failure.malformed }
        guard bytes[0] == wrapVersion else { throw Failure.unsupportedVersion }
        let length = Int(bytes[1]) << 8 | Int(bytes[2])
        guard bytes.count > 3 + length else { throw Failure.malformed }
        let enc = Data(bytes[3..<(3 + length)])
        let sealed = Data(bytes[(3 + length)...])
        var recipient = try HPKE.Recipient(
            privateKey: phone, ciphersuite: suite, info: wrapContext(macID, phoneID), encapsulatedKey: enc)
        let raw = try recipient.open(sealed)
        guard raw.count == keyByteCount else { throw Failure.malformed }
        return SymmetricKey(data: raw)
    }

    private static func wrapContext(_ macID: String, _ phoneID: String) -> Data {
        Data("quotabar-sync-key-v1\n\(macID)\n\(phoneID)".utf8)
    }

    // MARK: Telling the owner which phone it is

    /// Six digits from the phone's public key, shown on the phone and beside
    /// it on the Mac. The server hands the Mac the key it seals to; matching
    /// digits say it is the phone in the owner's hand and not one the server
    /// slipped in.
    public static func safetyCode(for agreementKey: Data) -> String {
        let digest = Array(SHA256.hash(data: Data("quotabar-safety-code-v1".utf8) + agreementKey))
        let number = (UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])) % 1_000_000
        let digits = String(format: "%06u", number)
        return "\(digits.prefix(3)) \(digits.suffix(3))"
    }
}
