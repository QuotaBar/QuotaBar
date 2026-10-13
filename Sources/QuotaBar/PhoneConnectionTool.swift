import Foundation
import QuotaRelay

/// A one-shot maintenance command using the app's existing signed identity.
/// Removal requires both safety codes and refuses an allowed or ambiguous target.
@MainActor
enum PhoneConnectionTool {
    static func code(_ phone: RelayClient.Phone) -> String? {
        guard let raw = phone.agreementKey, let data = Base64URL.decode(raw) else { return nil }
        return SyncCrypto.safetyCode(for: data).replacingOccurrences(of: " ", with: "")
    }

    static func run(arguments: [String]) async {
        do {
            let run = RunCenter()
            guard let client = run.relayClient() else {
                print("ERROR: current Mac connection is unavailable")
                return
            }
            let phones = try await client.phones()
            for phone in phones {
                print("phone id=\(phone.deviceId) code=\(code(phone) ?? "unknown") allowed=\(phone.grantedAt != nil)")
            }
            guard let removeIndex = arguments.firstIndex(of: "--remove-code") else { return }
            guard removeIndex + 1 < arguments.count,
                  let keepIndex = arguments.firstIndex(of: "--keep-code"), keepIndex + 1 < arguments.count else {
                print("ERROR: both removal and retention codes are required")
                return
            }
            let oldCode = arguments[removeIndex + 1].replacingOccurrences(of: " ", with: "")
            let keepCode = arguments[keepIndex + 1].replacingOccurrences(of: " ", with: "")
            let old = phones.filter { code($0) == oldCode }
            let kept = phones.filter { code($0) == keepCode }
            guard old.count == 1, kept.count == 1,
                  old[0].deviceId != kept[0].deviceId,
                  old[0].grantedAt == nil, kept[0].grantedAt != nil else {
                print("ERROR: safety checks refused removal")
                return
            }
            try await client.removePhone(old[0].deviceId)
            let after = try await client.phones()
            guard !after.contains(where: { $0.deviceId == old[0].deviceId }),
                  after.contains(where: { $0.deviceId == kept[0].deviceId && $0.grantedAt == kept[0].grantedAt }) else {
                print("ERROR: post-removal state requires inspection")
                return
            }
            print("REMOVED code=\(oldCode); RETAINED code=\(keepCode) allowed=true; remaining=\(after.count)")
        } catch {
            print("ERROR: \(error.localizedDescription)")
        }
    }
}
