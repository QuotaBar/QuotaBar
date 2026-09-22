import CloudKit
import XCTest
import QuotaCloud
import QuotaModel

/// The record is built and read without a container, so this runs without
/// the iCloud entitlement.
final class CloudReadingsRecordTests: XCTestCase {
    func testReadingsSurviveTheRecord() throws {
        let readings = CloudReadings(
            deviceID: "5F0C-mac", deviceName: "Studio", appVersion: "0.6.0", language: "en",
            updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
            providers: [.init(id: "codex", snapshot: UsageSnapshot(
                planName: "Pro", account: "someone@example.com",
                windows: [UsageWindow(title: "5h", usedPercent: 31, windowSeconds: 18_000)],
                fetchedAt: Date(timeIntervalSince1970: 1_790_000_000)))])
        let record = try CloudReadingsRecord.make(readings)
        XCTAssertEqual(record.recordID.recordName, "5F0C-mac")
        XCTAssertEqual(record.recordID.zoneID.zoneName, CloudNames.zone)
        // The account and the figures are only ever in the encrypted field.
        XCTAssertNil(record["payload"])
        XCTAssertEqual(record.encryptedValues.allKeys(), ["payload"])

        let back = try XCTUnwrap(CloudReadingsRecord.readings(from: record))
        XCTAssertEqual(back.deviceName, "Studio")
        XCTAssertEqual(back.providers.first?.snapshot?.account, "someone@example.com")
        XCTAssertEqual(back.providers.first?.snapshot?.windows.first?.usedPercent, 31)
    }

    func testForeignRecordIsIgnored() {
        let record = CKRecord(recordType: "Something", recordID: CKRecord.ID(recordName: "x", zoneID: CloudNames.zoneID))
        XCTAssertNil(CloudReadingsRecord.readings(from: record))
    }
}
