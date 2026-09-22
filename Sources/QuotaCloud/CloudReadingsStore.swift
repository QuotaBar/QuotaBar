import CloudKit
import Foundation
import QuotaModel

// MARK: - Where the readings live in iCloud

/// Names shared by the Mac that writes and the phone that reads. Changing any
/// of them strands every record already written.
public enum CloudNames {
    public static let container = "iCloud.bar.quota.QuotaBar"
    /// A zone of its own in the private database: change tracking and a
    /// database subscription both need one — the default zone has neither.
    public static let zone = "Readings"
    public static let recordType = "MacReadings"
    public static let subscription = "readings-changed"
    /// One record, overwritten by whichever phone asks last.
    public static let requestType = "RefreshRequest"
    public static let requestName = "refresh-request"

    public static var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zone, ownerName: CKCurrentUserDefaultName)
    }
}

// MARK: - A Mac's readings as a record

/// One record per Mac, named after its device id. The readings go in an
/// encrypted field: CloudKit keeps the key in the owner's iCloud Keychain, so
/// not even the database can read which accounts and plans they name. Only
/// the version and the time are left plain, for looking at in the console.
public enum CloudReadingsRecord {
    public enum Field {
        public static let payload = "payload"
        public static let version = "version"
        public static let updatedAt = "updatedAt"
    }

    public static func make(_ readings: CloudReadings, zoneID: CKRecordZone.ID = CloudNames.zoneID) throws -> CKRecord {
        let id = CKRecord.ID(recordName: readings.deviceID, zoneID: zoneID)
        let record = CKRecord(recordType: CloudNames.recordType, recordID: id)
        record.encryptedValues[Field.payload] = try readings.encoded()
        record[Field.version] = readings.version as NSNumber
        record[Field.updatedAt] = readings.updatedAt as NSDate
        return record
    }

    /// Nil for a record that is not ours or does not decode; one bad Mac
    /// does not hide the others.
    public static func readings(from record: CKRecord) -> CloudReadings? {
        guard record.recordType == CloudNames.recordType,
              let data = record.encryptedValues[Field.payload] as? Data
        else { return nil }
        return try? CloudReadings.decode(data)
    }
}

// MARK: - Reading and writing

public enum CloudSyncError: LocalizedError, Sendable {
    /// This build carries no iCloud entitlement — a development build, or
    /// one signed without the provisioning profile.
    case notEntitled
    case noAccount
    case restricted
    case temporarilyUnavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notEntitled:
            L10n.t("This build cannot use iCloud.", "这个版本不能使用 iCloud。")
        case .noAccount:
            L10n.t("Not signed in to iCloud. Sign in in Settings.", "尚未登录 iCloud，请在设置中登录。")
        case .restricted:
            L10n.t("iCloud is restricted on this device.", "这台设备上的 iCloud 受限制。")
        case .temporarilyUnavailable:
            L10n.t("iCloud is temporarily unavailable.", "iCloud 暂时不可用。")
        case let .failed(message):
            message
        }
    }
}

/// The private database's side of the sync. The Mac writes its own record;
/// the phone reads every Mac's. Nothing here touches CloudKit until a method
/// is called, and `CloudEntitlement.present` must be checked first on the
/// Mac: a CloudKit call from a process without the entitlement traps.
public actor CloudReadingsStore {
    private let container: CKContainer
    private var database: CKDatabase { container.privateCloudDatabase }
    private var zoneReady = false

    public init(containerIdentifier: String = CloudNames.container) {
        container = CKContainer(identifier: containerIdentifier)
    }

    /// Whether the owner is signed in to iCloud with it available to us.
    public func checkAccount() async throws {
        let status: CKAccountStatus
        do {
            status = try await container.accountStatus()
        } catch {
            throw Self.mapped(error)
        }
        switch status {
        case .available: return
        case .noAccount: throw CloudSyncError.noAccount
        case .restricted: throw CloudSyncError.restricted
        case .temporarilyUnavailable, .couldNotDetermine: throw CloudSyncError.temporarilyUnavailable
        @unknown default: throw CloudSyncError.temporarilyUnavailable
        }
    }

    /// Replaces this Mac's record. `.allKeys` overwrites whatever is there
    /// without fetching it first: the Mac is the only writer of its record,
    /// so there is nothing on the server to merge with.
    public func write(_ readings: CloudReadings) async throws {
        let record = try CloudReadingsRecord.make(readings)
        do {
            try await ensureZone()
            try await save(record)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            // The owner cleared the app's iCloud data: make the zone again.
            zoneReady = false
            try await ensureZone()
            try await save(record)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Takes this Mac's record away, when the owner turns syncing off.
    public func remove(deviceID: String) async throws {
        let id = CKRecord.ID(recordName: deviceID, zoneID: CloudNames.zoneID)
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [id])
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem {
            return
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Every Mac's readings. An empty list when no Mac has written yet.
    public func readAll() async throws -> [CloudReadings] {
        var found: [CloudReadings] = []
        var token: CKServerChangeToken?
        do {
            while true {
                let changes = try await database.recordZoneChanges(inZoneWith: CloudNames.zoneID, since: token)
                for (_, result) in changes.modificationResultsByID {
                    if case let .success(modification) = result,
                       let readings = CloudReadingsRecord.readings(from: modification.record)
                    {
                        found.append(readings)
                    }
                }
                token = changes.changeToken
                if !changes.moreComing { break }
            }
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            return []
        } catch {
            throw Self.mapped(error)
        }
        return found
    }

    /// The phone's "refresh now". Overwrites the one before: only the latest
    /// matters, and each Mac keeps its own note of what it has handled.
    public func requestRefresh(from device: String, at date: Date = .now) async throws {
        let record = CKRecord(
            recordType: CloudNames.requestType,
            recordID: CKRecord.ID(recordName: CloudNames.requestName, zoneID: CloudNames.zoneID))
        record["requestedAt"] = date as NSDate
        record.encryptedValues["from"] = device
        do {
            try await ensureZone()
            try await save(record)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            zoneReady = false
            try await ensureZone()
            try await save(record)
        } catch {
            throw Self.mapped(error)
        }
    }

    /// The latest request, or nil when no phone has asked.
    public func latestRefreshRequest() async throws -> CloudRefreshRequest? {
        let id = CKRecord.ID(recordName: CloudNames.requestName, zoneID: CloudNames.zoneID)
        do {
            let record = try await database.record(for: id)
            guard let date = record["requestedAt"] as? Date else { return nil }
            return CloudRefreshRequest(requestedAt: date, from: record.encryptedValues["from"] as? String ?? "iPhone")
        } catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound || error.code == .userDeletedZone {
            return nil
        } catch {
            throw Self.mapped(error)
        }
    }

    /// Asks CloudKit to wake the phone when any Mac writes. Silent pushes are
    /// throttled by the system, so this makes an update likely, not certain;
    /// the widgets refresh on their own schedule as well.
    public func subscribe() async throws {
        let subscription = CKDatabaseSubscription(subscriptionID: CloudNames.subscription)
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        subscription.notificationInfo = info
        do {
            _ = try await database.modifySubscriptions(saving: [subscription], deleting: [])
        } catch {
            throw Self.mapped(error)
        }
    }

    private func ensureZone() async throws {
        guard !zoneReady else { return }
        _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: CloudNames.zoneID)], deleting: [])
        zoneReady = true
    }

    private func save(_ record: CKRecord) async throws {
        let result = try await database.modifyRecords(
            saving: [record], deleting: [], savePolicy: .allKeys, atomically: false)
        if case let .failure(error) = result.saveResults[record.recordID] { throw error }
    }

    private static func mapped(_ error: Error) -> Error {
        if error is CloudSyncError { return error }
        guard let error = error as? CKError else { return CloudSyncError.failed(error.localizedDescription) }
        switch error.code {
        case .notAuthenticated: return CloudSyncError.noAccount
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return CloudSyncError.temporarilyUnavailable
        default: return CloudSyncError.failed(error.localizedDescription)
        }
    }
}

// MARK: - Whether this build may use iCloud at all

#if os(macOS)
import Security

/// The Mac app ships outside the App Store, and only a build signed with the
/// Developer ID provisioning profile carries the iCloud entitlement. Ad-hoc
/// and development builds do not, and CloudKit traps when called without it,
/// so the Mac asks before touching it.
public enum CloudEntitlement {
    public static let present: Bool = {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        else { return false }
        return (value as? [String])?.contains("CloudKit") ?? false
    }()
}
#endif
