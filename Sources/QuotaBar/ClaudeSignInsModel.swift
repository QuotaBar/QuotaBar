import SwiftUI
import QuotaCore

/// The Claude Code sign-ins besides the card's (issue #8) — one per
/// `CLAUDE_CONFIG_DIR`, often another organization of the same email — read
/// on the card's beat. Kept apart from `UsageSnapshot`, like the Codex
/// accounts, so they stay on the Mac that holds them.
@MainActor
final class ClaudeSignInsModel: ObservableObject {
    @Published private(set) var others: [ClaudeSignIns.Reading] = []
    /// Who the card's own sign-in is.
    @Published private(set) var card: ClaudeProvider.Identity?
    private var reading = false

    /// A failure keeps the last good figures beside the reason.
    func read() async {
        guard !reading else { return }
        reading = true
        defer { reading = false }
        card = await ClaudeSignIns.cardIdentity()
        let fresh = await ClaudeSignIns.readOthers()
        let last = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        others = fresh.map { reading in
            var reading = reading
            if reading.snapshot == nil { reading.snapshot = last[reading.id]?.snapshot }
            if reading.identity == nil { reading.identity = last[reading.id]?.identity }
            return reading
        }
    }

    /// Off-screen renders (`--snapshot`): sign-ins to draw, without the keychain.
    func seedForPreview(card: ClaudeProvider.Identity?, others: [ClaudeSignIns.Reading]) {
        self.card = card
        self.others = others
    }

    /// The organization, which is what tells two sign-ins of one email
    /// apart; else the email; numbered when neither is to be shown.
    func label(_ identity: ClaudeProvider.Identity?, number: Int, masked: Bool) -> String {
        if !masked, let name = identity?.organization ?? identity?.email { return name }
        return L10n.t("Organization \(number)", "组织 \(number)")
    }

    /// The email under an organization's name, when it adds something.
    func detail(_ identity: ClaudeProvider.Identity?, masked: Bool) -> String? {
        guard !masked, identity?.organization != nil else { return nil }
        return identity?.email
    }
}
