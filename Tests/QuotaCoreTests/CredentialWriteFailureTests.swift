import XCTest
@testable import QuotaCore

final class CredentialWriteFailureTests: XCTestCase {
    private final class RejectingStorage: CredentialStorage, @unchecked Sendable {
        func read(account: String) -> String? { "original-credential" }
        func write(_ value: String, account: String) -> Bool { false }
        func delete(account: String) -> Bool { false }
    }

    private func withStore(storage: CredentialStorage = RejectingStorage(), _ run: (ConfigStore) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        run(ConfigStore(fileURL: folder.appendingPathComponent("config.json"), credentials: storage))
    }

    func testFailedSaveDoesNotExposeUnsavedCredentialThroughMemo() {
        withStore { store in
            XCTAssertEqual(store.credential(for: .kimi), "original-credential")
            XCTAssertFalse(store.setCredential("replacement", for: .kimi))
            XCTAssertNotNil(store.lastCredentialError)
            XCTAssertEqual(store.credential(for: .kimi), "original-credential")
            store.invalidateCredentialCache()
            XCTAssertEqual(store.credential(for: .kimi), "original-credential")
        }
    }

    func testFailedClearDoesNotPretendAccountWasRemoved() {
        withStore { store in
            XCTAssertEqual(store.credential(for: .cursor), "original-credential")
            XCTAssertFalse(store.setCredential(nil, for: .cursor))
            XCTAssertNotNil(store.lastCredentialError)
            XCTAssertEqual(store.credential(for: .cursor), "original-credential")
        }
    }

    private final class SlowStorage: CredentialStorage, @unchecked Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: String? = "old-account"
        private var first = true

        func read(account: String) -> String? {
            lock.lock()
            let captured = value, hold = first
            first = false
            lock.unlock()
            if hold {
                started.signal()
                _ = release.wait(timeout: .now() + 5)
            }
            return captured
        }
        func write(_ value: String, account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            self.value = value
            return true
        }
        func delete(account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            value = nil
            return true
        }
    }

    func testSlowOldKeychainReadCannotOverwriteSavedAccountOrSignOut() {
        for replacement in [String?.some("new-account"), nil] {
            let storage = SlowStorage()
            withStore(storage: storage) { store in
                let done = expectation(description: "old read finishes")
                DispatchQueue.global().async {
                    XCTAssertEqual(store.credential(for: .cursor), replacement)
                    done.fulfill()
                }
                XCTAssertEqual(storage.started.wait(timeout: .now() + 2), .success)
                XCTAssertTrue(store.setCredential(replacement, for: .cursor))
                storage.release.signal()
                wait(for: [done], timeout: 5)
                XCTAssertEqual(store.credential(for: .cursor), replacement)
            }
        }
    }
}
