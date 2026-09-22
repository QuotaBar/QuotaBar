import CryptoKit
import Foundation
import QuotaCore

// MARK: - The readings, to phones on the owner's Quota Run account

/// What the Quota Run route to the iPhone is doing, said in Settings.
enum RelaySyncStatus: Equatable {
    /// This Mac is not on a Quota Run account.
    case signedOut
    /// On one, and no phone allowed yet: nothing is sent.
    case idle
    case synced(Date)
    case failed(String)
}

/// Sends this Mac's readings to the owner's iPhones through their Quota Run
/// account — for a phone on another iCloud account, which the iCloud route
/// cannot reach.
///
/// quota.run only relays: the readings are sealed with a key only this Mac
/// makes (`SyncCrypto`), and a phone gets that key when the owner allows it
/// here, sealed to that phone's own public key. Nothing is sent until a
/// phone is allowed, and revoking one changes the key, so what it held stops
/// opening anything new.
///
/// Its own object, like `CloudSyncCenter`, so Settings redraws without the
/// menu-bar item.
@MainActor
final class RelaySyncCenter: ObservableObject {
    @Published private(set) var status: RelaySyncStatus = .signedOut
    /// The phones on the account, as quota.run lists them to this Mac.
    @Published private(set) var phones: [RelayClient.Phone] = []
    @Published private(set) var phonesLoaded = false
    /// Why the phones could not be listed; the list is then what it was.
    @Published private(set) var phonesError: String?
    /// The phone an Allow or Revoke is under way for.
    @Published private(set) var working: String?
    /// Why the last Allow or Revoke did not go through.
    @Published private(set) var actionError: String?
    /// The last "refresh now" a phone sent this way and this Mac acted on.
    @Published private(set) var lastRequest: CloudRefreshRequest?

    private let inert: Bool
    private var client: () -> RelayClient? = { nil }
    private var readings: (() -> CloudReadings)?
    private var refreshAll: (() -> Void)?
    private var notify: ((String, String) -> Void)?
    private var loopTask: Task<Void, Never>?
    private var last: (signature: CloudReadings.Signature, at: Date)?
    private var uploading = false
    private var phonesLoadedAt: Date?
    private var requestCheckedAt: Date?
    private var lastHandled: Date?
    private var lastRequestedRefresh: Date?
    private var forceNextWrite = false
    /// Settings is showing the phones: they are looked up far more often, so
    /// a phone that just signed in shows up while the owner waits for it.
    private var watchers = 0

    init(inert: Bool = false) {
        self.inert = inert
    }

    private var hasAllowedPhone: Bool { phones.contains { $0.grantedAt != nil } }

    func start(
        client: @escaping () -> RelayClient?,
        readings: @escaping () -> CloudReadings,
        refreshAll: @escaping () -> Void,
        notify: @escaping (_ title: String, _ body: String) -> Void)
    {
        guard !inert else { return }
        self.client = client
        self.readings = readings
        self.refreshAll = refreshAll
        self.notify = notify
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            // Let the first refresh land first.
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Settings' phone list appeared or went away.
    func watch(_ on: Bool) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if on { Task { await loadPhones() } }
    }

    /// One pass of the loop: the phones every five minutes (every ten
    /// seconds while Settings shows them), and — once a phone is allowed —
    /// a heartbeat write and a look for its "refresh now".
    private func tick() async {
        guard let client = client() else {
            signedOut()
            return
        }
        let now = Date()
        let phonesDue = phonesLoadedAt.map { now.timeIntervalSince($0) >= (watchers > 0 ? 10 : 300) } ?? true
        if phonesDue { await loadPhones() }
        guard hasAllowedPhone else {
            if case .failed = status {} else { status = .idle }
            return
        }
        writeIfDue()
        if requestCheckedAt.map({ now.timeIntervalSince($0) >= RefreshRequestPolicy.pollInterval }) ?? true {
            requestCheckedAt = now
            await checkForRequest(client)
        }
    }

    /// Off the account: nothing to send, and the key has nowhere to go.
    private func signedOut() {
        guard status != .signedOut || !phones.isEmpty else { return }
        status = .signedOut
        phones = []
        phonesLoaded = false
        phonesError = nil
        phonesLoadedAt = nil
        last = nil
        RelaySyncKey.forget()
    }

    func loadPhones() async {
        guard let client = client() else { return signedOut() }
        do {
            let fresh = try await client.phones()
            phonesLoadedAt = Date()
            announce(fresh)
            phones = fresh
            phonesLoaded = true
            phonesError = nil
        } catch {
            phonesLoadedAt = Date()
            phonesLoaded = true
            phonesError = error.localizedDescription
            RelaySyncLog.note("could not list phones: \(error.localizedDescription)")
        }
    }

    /// A phone that signed in and is waiting to be allowed: said once, as a
    /// notification, since the owner is holding the phone, not this Mac.
    private func announce(_ fresh: [RelayClient.Phone]) {
        var told = RelaySyncKey.announced
        for phone in fresh where phone.grantedAt == nil && phone.agreementKey != nil && !told.contains(phone.deviceId) {
            told.insert(phone.deviceId)
            notify?(
                L10n.t("\(phone.name) wants this Mac's readings", "\(phone.name) 想看这台 Mac 的额度"),
                L10n.t(
                    "Open Settings › iPhone in QuotaBar and allow it if the code matches the one on the phone.",
                    "在 QuotaBar 的 设置 › iPhone 里核对手机上显示的安全码，一致就点“允许”。"))
        }
        // Forget phones that are gone, so the list does not grow forever.
        RelaySyncKey.announced = told.intersection(fresh.map(\.deviceId))
    }

    // MARK: Allowing and revoking

    func allow(_ phone: RelayClient.Phone) {
        guard working == nil, let client = client(), let deviceID = client.deviceID,
              let encoded = phone.agreementKey, let raw = Base64URL.decode(encoded),
              let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: raw)
        else { return }
        working = phone.deviceId
        actionError = nil
        Task {
            defer { working = nil }
            do {
                let key = try RelaySyncKey.current(for: deviceID)
                let wrapped = try SyncCrypto.wrap(key, for: publicKey, macID: deviceID, phoneID: phone.deviceId)
                try await client.grant(wrapped, to: phone.deviceId, agreementKey: encoded)
                RelaySyncLog.note("allowed \(phone.name)")
                await loadPhones()
                await upload(client: client, force: true)
            } catch let error as RelayError where error.code == "agreement_key_changed" {
                await loadPhones()
                actionError = L10n.t(
                    "\(phone.name) has a new key since. Check the code again, then allow it.",
                    "\(phone.name) 刚换了密钥，请重新核对安全码后再允许。")
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    /// Takes the key back from one phone. The key changes, and every other
    /// allowed phone gets the new one, so the revoked phone's copy opens
    /// nothing sent from now on.
    func revoke(_ phone: RelayClient.Phone) {
        guard working == nil, let client = client(), let deviceID = client.deviceID else { return }
        working = phone.deviceId
        actionError = nil
        Task {
            defer { working = nil }
            do {
                try await client.revoke(phone.deviceId)
                let key = try RelaySyncKey.replace(for: deviceID)
                for other in phones where other.deviceId != phone.deviceId && other.grantedAt != nil {
                    guard let encoded = other.agreementKey, let raw = Base64URL.decode(encoded),
                          let publicKey = try? P256.KeyAgreement.PublicKey(x963Representation: raw),
                          let wrapped = try? SyncCrypto.wrap(key, for: publicKey, macID: deviceID, phoneID: other.deviceId)
                    else { continue }
                    // A phone whose key changed meanwhile drops back to
                    // waiting, and is allowed again like a new one.
                    try? await client.grant(wrapped, to: other.deviceId, agreementKey: encoded)
                }
                RelaySyncLog.note("revoked \(phone.name); key replaced")
                // Even with no phone left: what quota.run holds is then
                // sealed with a key nobody has.
                await upload(client: client, force: true)
                await loadPhones()
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    // MARK: Sending

    func afterRefresh() {
        writeIfDue(force: forceNextWrite)
    }

    func syncNow() {
        writeIfDue(force: true)
    }

    private func writeIfDue(force: Bool = false) {
        guard hasAllowedPhone, let client = client() else { return }
        Task { await upload(client: client, force: force) }
    }

    private func upload(client: RelayClient, force: Bool) async {
        guard !uploading, let readings, let deviceID = client.deviceID else { return }
        let current = readings()
        let signature = current.signature
        guard force || CloudSyncPolicy.shouldWrite(current: signature, last: last, now: current.updatedAt) else { return }
        uploading = true
        defer { uploading = false }
        do {
            let key = try RelaySyncKey.current(for: deviceID)
            try await client.putReadings(RelayReadings.seal(current, key: key, macID: deviceID))
            last = (signature, current.updatedAt)
            forceNextWrite = false
            status = .synced(current.updatedAt)
        } catch {
            status = .failed(error.localizedDescription)
            RelaySyncLog.note("upload failed: \(error.localizedDescription)")
        }
    }

    // MARK: A phone's "refresh now"

    private func checkForRequest(_ client: RelayClient) async {
        guard let latest = try? await client.latestRefreshRequest(), let at = latest.requestedAt else { return }
        let request = CloudRefreshRequest(requestedAt: Date(timeIntervalSince1970: at), from: latest.from ?? "iPhone")
        let now = Date()
        guard RefreshRequestPolicy.shouldHonor(
            request, lastHandled: lastHandled, lastRequestedRefresh: lastRequestedRefresh, now: now)
        else {
            if lastHandled.map({ request.requestedAt > $0 }) ?? true { lastHandled = request.requestedAt }
            return
        }
        lastHandled = request.requestedAt
        lastRequestedRefresh = now
        lastRequest = request
        forceNextWrite = true
        RelaySyncLog.note("refreshing for \(request.from), asked at \(request.requestedAt)")
        refreshAll?()
    }
}

// MARK: - The sync key

/// This Mac's sync key in the keychain, kept with the Quota Run device it
/// belongs to: joining again as another device starts a new key.
enum RelaySyncKey {
    private static let service = "bar.quota.run.sync-key"
    private static let account = "sync"
    private static let announcedKey = "relayAnnouncedPhones"

    static func current(for deviceID: String) throws -> SymmetricKey {
        if let stored = Keychain.read(account: account, service: service) {
            let parts = stored.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == deviceID, let raw = Data(base64Encoded: parts[1]),
               raw.count == SyncCrypto.keyByteCount
            {
                return SymmetricKey(data: raw)
            }
        }
        return try replace(for: deviceID)
    }

    static func replace(for deviceID: String) throws -> SymmetricKey {
        let key = SyncCrypto.newKey()
        let raw = key.withUnsafeBytes { Data($0) }
        guard Keychain.write("\(deviceID):\(raw.base64EncodedString())", account: account, service: service) else {
            throw RunDeviceKey.KeyError.keychainRefused
        }
        return key
    }

    static func forget() {
        Keychain.delete(account: account, service: service)
        UserDefaults.standard.removeObject(forKey: announcedKey)
    }

    /// Phones already announced with a notification.
    static var announced: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: announcedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: announcedKey) }
    }
}

/// Outcomes only, beside the iCloud log.
enum RelaySyncLog {
    static func note(_ line: String) {
        CloudSyncLog.note("quota.run: \(line)")
    }
}
