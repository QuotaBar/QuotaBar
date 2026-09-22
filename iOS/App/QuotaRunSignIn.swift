import QuotaModel
import QuotaRelay
import SafariServices
import SwiftUI
import UIKit

// MARK: - Signing in to Quota Run

/// This phone joining the owner's Quota Run account, as the Mac does: a
/// fresh key pair, a connection code, and the owner approving it on
/// quota.run — GitHub, Google, Apple or an email code, whichever they use
/// there. The phone never sees a password or a token.
@MainActor
@Observable
final class QuotaRunSession {
    enum Phase: Equatable {
        case idle
        case starting
        /// The page is open; waiting for the owner to approve.
        case waiting(url: URL)
        case failed(String)
    }

    private(set) var account: QuotaRunAccount?
    private(set) var macs: [RelayMac]
    private(set) var phase: Phase = .idle
    /// The approval page, in a sheet over the app.
    var showsPage = false
    /// Shown here and on the Mac beside this phone, to be matched before
    /// the owner allows it.
    private(set) var safetyCode: String?
    private(set) var isSigningOut = false

    private var attempt = 0
    private var task: Task<Void, Never>?

    init() {
        account = QuotaRunStore.account
        macs = RelayCache.load().macs
        safetyCode = account != nil ? QuotaRunStore.loadKeys()?.safetyCode : nil
    }

    /// After a fetch: the Macs and whether this phone is still signed in.
    func reload() {
        account = QuotaRunStore.account
        macs = account != nil ? RelayCache.load().macs : []
        safetyCode = account != nil ? QuotaRunStore.loadKeys()?.safetyCode : nil
    }

    /// Macs on the account that have not allowed this phone yet.
    var waitingMacs: [RelayMac] { macs.filter { $0.state == .waiting || $0.state == .unreadable } }

    func signIn(then approved: @escaping @MainActor () async -> Void) {
        guard account == nil, phase == .idle || isFailed else { return }
        attempt &+= 1
        let current = attempt
        phase = .starting
        task = Task { await connect(attempt: current, then: approved) }
    }

    private var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    /// Called off: the keys made for it were never stored, so nothing is
    /// left behind.
    func cancel() {
        attempt &+= 1
        task?.cancel()
        task = nil
        showsPage = false
        phase = .idle
    }

    private func connect(attempt current: Int, then approved: @escaping @MainActor () async -> Void) async {
        let keys = QuotaRunStore.Keys.fresh()
        let client = QuotaRunStore.client(signing: keys.signing)
        do {
            let start = try await client.connectStart(
                deviceName: UIDevice.current.name, appVersion: Self.appVersion, chinese: L10n.isChinese)
            guard current == attempt else { return }
            #if DEBUG
            // For a scripted approval against a local server: where the
            // page is, in Documents (see `RelayScenario` in the Mac tests).
            if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? start.verifyURL.absoluteString.write(
                    to: folder.appendingPathComponent("connect-url.txt"), atomically: true, encoding: .utf8)
            }
            #endif
            phase = .waiting(url: start.verifyURL)
            showsPage = true
            let expires = Date(timeIntervalSince1970: start.expiresAt)
            var wait = max(start.interval, 2)
            while true {
                try await Task.sleep(for: .seconds(wait))
                guard current == attempt else { return }
                guard Date() < expires.addingTimeInterval(wait) else {
                    return fail(L10n.t("The code expired. Try again.", "连接码已过期，请重试。"))
                }
                let poll: RelayClient.ConnectPoll
                do {
                    poll = try await client.connectPoll(requestID: start.requestId)
                    wait = max(start.interval, 2)
                } catch let error as RelayError where error.status == 429 || error.status >= 500 {
                    wait = max(start.interval, 2) * 2
                    continue
                } catch is URLError {
                    wait = max(start.interval, 2) * 2
                    continue
                }
                guard current == attempt else { return }
                switch poll.status {
                case "pending":
                    continue
                case "approved":
                    guard let deviceID = poll.deviceId, let user = poll.user else {
                        return fail(L10n.t("quota.run answered in a form this app does not read.", "quota.run 的回应无法识别。"))
                    }
                    guard QuotaRunStore.save(keys) else {
                        return fail(L10n.t("The keychain refused to store this phone's key.", "钥匙串拒绝保存这台手机的密钥。"))
                    }
                    QuotaRunStore.account = QuotaRunAccount(
                        username: user.username, displayName: user.displayName, deviceID: deviceID, connectedAt: Date())
                    QuotaRunStore.agreementKeySent = false
                    showsPage = false
                    phase = .idle
                    task = nil
                    reload()
                    await approved()
                    return
                case "denied":
                    return fail(L10n.t("The connection was declined on quota.run.", "已在 quota.run 上拒绝了这次连接。"))
                default:
                    return fail(L10n.t("The code expired. Try again.", "连接码已过期，请重试。"))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard current == attempt else { return }
            fail(error.localizedDescription)
        }
    }

    private func fail(_ message: String) {
        showsPage = false
        phase = .failed(message)
        task = nil
    }

    /// Off the account: quota.run forgets this phone and everything sealed
    /// to it, and the keys go from this phone. Signed out here even when
    /// quota.run cannot be reached — the account page can remove it later.
    func signOut(then done: @escaping @MainActor () async -> Void) {
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            if let (client, _, _) = QuotaRunStore.signedIn() {
                try? await client.disconnect()
            }
            QuotaRunStore.forget()
            isSigningOut = false
            reload()
            await done()
        }
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

// MARK: - The approval page

/// quota.run's connect page in Safari's own view: the owner's sign-ins
/// there are Safari's, never the app's.
struct ApprovalPage: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .cancel
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

// MARK: - In the sync sheet

/// The Quota Run route, in the sheet behind the question mark: signed out,
/// a button; signed in, the account, this phone's code and each Mac.
struct QuotaRunSection: View {
    let model: ReadingsModel
    @State private var confirmsSignOut = false

    private var session: QuotaRunSession { model.quotaRun }

    var body: some View {
        Section {
            if let account = session.account {
                LabeledContent(L10n.t("Account", "账号"), value: "@\(account.username)")
                if let code = session.safetyCode {
                    LabeledContent(L10n.t("This phone's code", "本机安全码")) {
                        Text(code).monospacedDigit()
                    }
                }
                ForEach(session.macs) { mac in
                    RelayMacRow(mac: mac)
                }
                Button(L10n.t("Sign out", "退出登录"), role: .destructive) { confirmsSignOut = true }
                    .disabled(session.isSigningOut)
                    .confirmationDialog(
                        L10n.t("Sign out of Quota Run?", "退出 Quota Run？"),
                        isPresented: $confirmsSignOut, titleVisibility: .visible)
                    {
                        Button(L10n.t("Sign out", "退出登录"), role: .destructive) {
                            session.signOut { await model.refresh() }
                        }
                    } message: {
                        Text(L10n.t(
                            "This phone leaves the account and stops receiving readings through quota.run. Readings from iCloud are not affected.",
                            "这台手机会离开账号，不再通过 quota.run 接收额度。iCloud 同步的数据不受影响。"))
                    }
            } else {
                SignInButton(model: model)
            }
        } header: {
            Text("Quota Run")
        } footer: {
            Text(session.account == nil
                ? L10n.t(
                    "Optional. For a Mac on another iCloud account: sign in to the Quota Run account the Mac uses, then allow this phone on the Mac. The readings are encrypted on the Mac for this phone alone; quota.run only passes them on.",
                    "可选。适用于和这台手机不是同一个 iCloud 账号的 Mac：登录 Mac 所用的 Quota Run 账号，再在 Mac 上允许这台手机。额度在 Mac 上只为这台手机加密，quota.run 只负责转交，读不到内容。")
                : session.waitingMacs.isEmpty && !session.macs.isEmpty
                ? L10n.t(
                    "Readings are encrypted on each Mac for this phone alone; quota.run only passes them on.",
                    "额度在每台 Mac 上只为这台手机加密，quota.run 只负责转交，读不到内容。")
                : L10n.t(
                    "On the Mac, open Settings › iPhone and allow this phone once its code matches the one above.",
                    "在 Mac 上打开 设置 › iPhone，核对安全码与上面一致后点“允许”。"))
        }
    }
}

/// The sign-in button with whatever the attempt is doing.
struct SignInButton: View {
    let model: ReadingsModel
    var prominent = false

    private var session: QuotaRunSession { model.quotaRun }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if case .waiting = session.phase {
                    session.showsPage = true
                } else {
                    session.signIn { await model.refresh() }
                }
            } label: {
                HStack(spacing: 8) {
                    if session.phase == .starting { ProgressView() }
                    Text(label)
                }
                .frame(maxWidth: prominent ? .infinity : nil)
            }
            .modifier(Prominence(prominent: prominent))
            .disabled(session.phase == .starting)
            if case .waiting = session.phase {
                Button(L10n.t("Cancel", "取消"), role: .cancel) { session.cancel() }
                    .font(.footnote)
            }
            if case let .failed(message) = session.phase {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var label: String {
        if case .waiting = session.phase { return L10n.t("Open the approval page again", "重新打开确认页面") }
        return L10n.t("Sign in to Quota Run", "登录 Quota Run")
    }

    private struct Prominence: ViewModifier {
        let prominent: Bool

        func body(content: Content) -> some View {
            if prominent {
                // The tint is the Mac's light neutral: dark type on it.
                content.buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(.black)
            } else {
                content
            }
        }
    }
}

private struct RelayMacRow: View {
    let mac: RelayMac

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name.isEmpty ? "Mac" : mac.name)
                    .font(.subheadline.weight(.medium))
                Text(state)
                    .font(.caption)
                    .foregroundStyle(mac.state == .readable ? Color.secondary : Color.orange)
            }
        }
    }

    private var state: String {
        switch mac.state {
        case .readable: L10n.t("Allowed · receiving readings", "已允许 · 正在接收")
        case .empty: L10n.t("Allowed · nothing sent yet", "已允许 · 还没有发送数据")
        case .waiting: L10n.t("Allow this phone on the Mac", "请在这台 Mac 上允许本机")
        case .unreadable: L10n.t("Allow this phone on the Mac again", "请在这台 Mac 上重新允许本机")
        }
    }
}

// MARK: - On the main page

/// Signed in, and a Mac still has to allow this phone: said where the cards
/// would be, with the code to match.
struct AllowOnMacPrompt: View {
    let macs: [RelayMac]
    let code: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L10n.t("Allow this phone on your Mac", "在 Mac 上允许这台手机"), systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
            Text(L10n.t(
                "On \(names), open QuotaBar › Settings › iPhone and allow this phone. Check that the code there matches:",
                "在 \(names) 上打开 QuotaBar › 设置 › iPhone，核对安全码一致后点“允许”。本机安全码："))
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let code {
                Text(code)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var names: String {
        macs.map { $0.name.isEmpty ? "Mac" : $0.name }.joined(separator: L10n.t(", ", "、"))
    }
}
