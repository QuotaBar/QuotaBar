import SwiftUI
import QuotaCore

/// Settings › Codex › "API credit key": an OpenAI API key for what is left of
/// the API credit the ChatGPT plan includes. Optional — without one the card
/// shows the allowance and its deadline — and one already on this Mac is
/// used when none is typed here.
struct CodexAPIKeySettings: View {
    @ObservedObject var store: UsageStore
    @State private var key: String
    @State private var saved: String
    @State private var reveal = false
    @State private var error: String?

    init(store: UsageStore) {
        self.store = store
        let value = ConfigStore.shared.openAIKey ?? ""
        _key = State(initialValue: value)
        _saved = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space2) {
            HStack(spacing: Design.space2) {
                GlassTextField(
                    placeholder: L10n.t("sk-admin-… or sk-… (optional)", "sk-admin-… 或 sk-…（可选）"),
                    text: $key,
                    secure: true,
                    reveal: $reveal,
                    onSubmit: save)
                Button(L10n.t("Save", "保存"), action: save)
                    .glassAction(prominent: true)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines) == saved)
                if !saved.isEmpty {
                    Button(L10n.t("Clear", "清除"), role: .destructive) {
                        key = ""
                        save()
                    }
                    .glassAction()
                }
            }
            Text(status)
                .font(.system(size: 11))
                .foregroundStyle(error == nil ? .secondary : Color.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Which key is used, from where, and what the last reading got.
    private var status: String {
        if let error { return error }
        var lines: [String] = []
        if !saved.isEmpty {
            lines.append(L10n.t("Using the key saved here (in the keychain).", "使用这里保存的 Key（存在钥匙串里）。"))
        } else {
            let found = CodexAPICredits.keys(saved: nil).map(\.source)
            lines.append(found.isEmpty
                ? L10n.t(
                    "Without a key the card shows the monthly allowance and its deadline. A key also shows what is left; none was found on this Mac (OPENAI_ADMIN_KEY, OPENAI_API_KEY, ~/.codex/auth.json, shell start-up files).",
                    "不填 Key 时，卡片显示每月额度和到期日；填了还能显示剩余。本机没有找到 Key（查找了 OPENAI_ADMIN_KEY、OPENAI_API_KEY、~/.codex/auth.json 和 shell 配置文件）。")
                : L10n.t("Found on this Mac: \(found.joined(separator: ", ")).", "已在本机找到：\(found.joined(separator: "、"))。"))
        }
        if let result = CodexAPICredits.lastKeyResult { lines.append(result.description) }
        return lines.joined(separator: " ")
    }

    private func save() {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ConfigStore.shared.setOpenAIKey(trimmed) else {
            error = ConfigStore.shared.lastCredentialError
            return
        }
        error = nil
        saved = trimmed
        key = trimmed
        CodexAPICredits.invalidateKeys()
        store.refresh(.codex)
    }
}
