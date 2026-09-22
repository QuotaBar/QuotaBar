import CryptoKit
import Foundation
import QuotaModel

// MARK: - The readings, through quota.run

/// A Mac's readings as they travel through a Quota Run account: the same
/// `CloudReadings` the iCloud record carries, sealed with that Mac's sync
/// key before it leaves, opened on a phone the Mac allowed.
public enum RelayReadings {
    /// Under the server's 512 KB cap, with room for the seal's 28 bytes.
    public static let limit = 500 * 1024

    public static func seal(_ readings: CloudReadings, key: SymmetricKey, macID: String) throws -> Data {
        try SyncCrypto.seal(readings.encoded(limit: limit), key: key, macID: macID)
    }

    /// One Mac on the account, as the phone finds it.
    public enum Opened: Sendable {
        /// The owner has not allowed this phone on that Mac yet.
        case waiting
        /// Allowed, and nothing sent since.
        case empty
        case readings(CloudReadings)
        /// Allowed once, but what is there does not open: the Mac changed
        /// its key since, or this phone did. It sorts itself out on the
        /// Mac's next grant.
        case unreadable
    }

    public static func open(
        _ mac: RelayClient.Mac, agreementKey: P256.KeyAgreement.PrivateKey, phoneID: String) -> Opened
    {
        guard let grant = mac.grant.flatMap(Base64URL.decode) else { return .waiting }
        guard let blob = mac.blob.flatMap(Base64URL.decode) else { return .empty }
        guard let key = try? SyncCrypto.unwrap(grant, with: agreementKey, macID: mac.deviceId, phoneID: phoneID),
              let data = try? SyncCrypto.open(blob, key: key, macID: mac.deviceId),
              let readings = try? CloudReadings.decode(data)
        else { return .unreadable }
        return .readings(readings)
    }
}
