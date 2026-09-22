import CryptoKit
import Foundation
import QuotaModel
import QuotaRelay
import Security

// MARK: - This phone on a Quota Run account

/// For a phone on another iCloud account than the Mac: it signs in to the
/// owner's Quota Run account and fetches each Mac's readings from quota.run,
/// sealed on the Mac. Optional — without it the phone reads iCloud alone.
struct QuotaRunAccount: Codable, Equatable {
    var username: String
    var displayName: String
    /// This phone's device id on quota.run.
    var deviceID: String
    var connectedAt: Date
}

/// The account, and the phone's two keys: one signs its requests, the other
/// is what each Mac seals its sync key to. Both are made on this phone and
/// never leave it; the keychain item is shared with the widgets through the
/// app group, so they can fetch on their own schedule.
enum QuotaRunStore {
    private static let accountKey = "quotaRunAccount"
    private static let agreementSentKey = "quotaRunAgreementKeySent"
    private static let keychainService = "bar.quota.run.phone"
    private static let keychainAccount = "keys"

    private static var defaults: UserDefaults? { UserDefaults(suiteName: ReadingsCache.appGroup) }

    static var base: URL {
        #if DEBUG
        // `-QuotaRunAPI http://…` points a debug build at a local server.
        if let raw = UserDefaults.standard.string(forKey: "QuotaRunAPI"), let url = URL(string: raw), url.host != nil {
            return url
        }
        #endif
        return RelayClient.productionBase
    }

    static var account: QuotaRunAccount? {
        get {
            guard let data = defaults?.data(forKey: accountKey) else { return nil }
            return try? JSONDecoder().decode(QuotaRunAccount.self, from: data)
        }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults?.set(data, forKey: accountKey)
            } else {
                defaults?.removeObject(forKey: accountKey)
            }
        }
    }

    /// Whether quota.run has this phone's agreement key. Sent right after
    /// joining, and again on the next fetch if that did not go through.
    static var agreementKeySent: Bool {
        get { defaults?.bool(forKey: agreementSentKey) ?? false }
        set { defaults?.set(newValue, forKey: agreementSentKey) }
    }

    // MARK: Keys

    struct Keys {
        var signing: P256.Signing.PrivateKey
        var agreement: P256.KeyAgreement.PrivateKey

        static func fresh() -> Keys {
            Keys(signing: P256.Signing.PrivateKey(), agreement: P256.KeyAgreement.PrivateKey())
        }

        /// What the phone shows so the owner can match it on the Mac.
        var safetyCode: String { SyncCrypto.safetyCode(for: agreement.publicKey.x963Representation) }
    }

    private struct StoredKeys: Codable {
        var signing: Data
        var agreement: Data
    }

    private static var keychainQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: ReadingsCache.appGroup,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func loadKeys() -> Keys? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
              let stored = try? JSONDecoder().decode(StoredKeys.self, from: data),
              let signing = try? P256.Signing.PrivateKey(rawRepresentation: stored.signing),
              let agreement = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored.agreement)
        else { return nil }
        return Keys(signing: signing, agreement: agreement)
    }

    static func save(_ keys: Keys) -> Bool {
        guard let data = try? JSONEncoder().encode(StoredKeys(
            signing: keys.signing.rawRepresentation, agreement: keys.agreement.rawRepresentation))
        else { return false }
        SecItemDelete(keychainQuery as CFDictionary)
        var item = keychainQuery
        item[kSecValueData as String] = data
        // After the first unlock, so a widget can fetch while the phone is
        // locked; this device only, so a backup does not carry it elsewhere.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    /// Signed out: the account, the keys and what came through quota.run.
    static func forget() {
        account = nil
        agreementKeySent = false
        SecItemDelete(keychainQuery as CFDictionary)
        RelayCache.clear()
    }

    static func client(signing: P256.Signing.PrivateKey, deviceID: String? = nil) -> RelayClient {
        RelayClient(base: base, signer: SoftwareRunSigner(key: signing), deviceID: deviceID)
    }

    /// The signed-in client, or nil when this phone is not on an account.
    static func signedIn() -> (client: RelayClient, account: QuotaRunAccount, keys: Keys)? {
        guard let account, let keys = loadKeys() else { return nil }
        return (client(signing: keys.signing, deviceID: account.deviceID), account, keys)
    }
}

// MARK: - The Macs, as quota.run lists them

/// One Mac on the account and whether this phone can read it.
struct RelayMac: Codable, Equatable, Identifiable {
    enum State: String, Codable {
        /// The owner has not allowed this phone on it yet.
        case waiting
        /// Allowed; nothing sent yet.
        case empty
        case readable
        /// Allowed once, but the key has changed since.
        case unreadable
    }

    var id: String
    var name: String
    var state: State
}

/// What came through quota.run last, beside the iCloud cache: a failed
/// fetch on either route leaves the other's readings alone.
enum RelayCache {
    private struct File: Codable {
        var devices: [CloudReadings]
        var macs: [RelayMac]
    }

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ReadingsCache.appGroup)?
            .appendingPathComponent("relay-readings.json")
    }

    static func load() -> (devices: [CloudReadings], macs: [RelayMac]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let url, let data = try? Data(contentsOf: url), let file = try? decoder.decode(File.self, from: data)
        else { return ([], []) }
        return (file.devices, file.macs)
    }

    static func save(devices: [CloudReadings], macs: [RelayMac]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let url, let data = try? encoder.encode(File(devices: devices, macs: macs)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func clear() {
        if let url { try? FileManager.default.removeItem(at: url) }
    }
}

enum RelaySync {
    /// Every Mac's readings this phone may open. Nil when the phone is not
    /// signed in; throws when quota.run could not be reached.
    static func fetch() async throws -> [CloudReadings]? {
        guard let (client, account, keys) = QuotaRunStore.signedIn() else { return nil }
        do {
            if !QuotaRunStore.agreementKeySent {
                try await client.putAgreementKey(keys.agreement.publicKey.x963Representation)
                QuotaRunStore.agreementKeySent = true
            }
            let listed = try await client.macs()
            var devices: [CloudReadings] = []
            var macs: [RelayMac] = []
            for mac in listed {
                let state: RelayMac.State
                switch RelayReadings.open(mac, agreementKey: keys.agreement, phoneID: account.deviceID) {
                case .waiting: state = .waiting
                case .empty: state = .empty
                case .unreadable: state = .unreadable
                case let .readings(readings):
                    state = .readable
                    devices.append(readings)
                }
                macs.append(RelayMac(id: mac.deviceId, name: mac.name, state: state))
            }
            RelayCache.save(devices: devices, macs: macs)
            return devices
        } catch let error as RelayError where error.code == "unknown_device" {
            // Removed from the account on quota.run: signed out here too.
            QuotaRunStore.forget()
            return nil
        }
    }
}
