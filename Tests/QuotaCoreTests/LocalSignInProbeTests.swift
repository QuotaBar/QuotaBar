import XCTest
@testable import QuotaCore
import QuotaModel

/// The z.ai and MiniMax cards against the real services, with the ZCode and
/// MiniMax Code sign-ins on this Mac. Prints readings, never a token.
/// Skipped unless `QUOTABAR_PROBE_LOCAL=1`; the renewal, which spends
/// MiniMax Code's refresh token for real, also needs `QUOTABAR_PROBE_RENEW=1`.
final class LocalSignInProbeTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PROBE_LOCAL"] == "1" else {
            throw XCTSkip("QUOTABAR_PROBE_LOCAL is not set")
        }
    }

    private func config() -> ConfigStore {
        ConfigStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(UUID().uuidString).json"),
            credentials: MemoryCredentialStorage())
    }

    private func show(_ name: String, _ snapshot: UsageSnapshot) {
        let account = snapshot.account.map { value -> String in
            if let at = value.firstIndex(of: "@") { return String(value.prefix(1)) + "***" + String(value[at...]) }
            return String(value.prefix(1)) + "*"
        } ?? "-"
        print("PROBE \(name) plan=\(snapshot.planName ?? "-") account=\(account)")
        for window in snapshot.windows {
            print("PROBE \(name)   \(window.title): used \(window.usedPercent.map { String(format: "%.1f%%", $0) } ?? "?")"
                + " \(window.detail ?? "") resets \(window.resetsAt.map { "\($0)" } ?? "-")")
        }
    }

    func testZaiWithZCodesSignIn() async throws {
        let provider = ZaiProvider()
        let config = config()
        XCTAssertTrue(provider.isConfigured(config: config))
        print("PROBE zai source: \(provider.sourceInfo(config: config)?.summary ?? "-")")
        show("zai", try await provider.fetch(config: config))
    }

    func testMiniMaxWithMiniMaxCodesSignIn() async throws {
        let signIn = try XCTUnwrap(MiniMaxCode.signIn())
        print("PROBE minimax sign-in \(signIn.region) status=\(signIn.status) generation=\(signIn.generation) expires in \(Int(signIn.expiresAt.timeIntervalSinceNow / 60)) min")
        let provider = MiniMaxProvider(environment: MiniMaxCodeEnvironment(mayRenew: true))
        let config = config()
        print("PROBE minimax source: \(provider.sourceInfo(config: config)?.summary ?? "-")")
        show("minimax", try await provider.fetch(config: config))
    }

    /// The shape of a reply: keys, numbers, and only the short labels a plan
    /// carries (names, titles, types), never a person's details.
    static func shape(_ value: Any, key: String = "", depth: Int = 0) -> String {
        guard depth < 7 else { return "…" }
        switch value {
        case let dict as [String: Any]:
            return "{" + dict.keys.sorted().map { "\($0): " + shape(dict[$0]!, key: $0, depth: depth + 1) }.joined(separator: ", ") + "}"
        case let array as [Any]:
            return "[" + array.prefix(3).map { shape($0, key: key, depth: depth + 1) }.joined(separator: ", ") + (array.count > 3 ? ", …\(array.count)" : "") + "]"
        case let text as String:
            let lower = key.lowercased()
            let personal = ["mail", "phone", "user", "nick", "token", "id", "avatar", "url", "code"].contains { lower.contains($0) }
            let label = ["name", "title", "plan", "level", "tier", "type", "status", "cycle", "desc", "msg"].contains { lower.contains($0) }
            return label && !personal && text.count <= 60 ? "\"\(text)\"" : "<str \(text.count)>"
        case let number as NSNumber:
            return "\(number)"
        default:
            return "null"
        }
    }

    func testMiniMaxPlanEndpointsShape() async throws {
        let signIn = try XCTUnwrap(MiniMaxCode.signIn())
        let headers = ["Authorization": "Bearer \(signIn.accessToken)", "Accept": "application/json"]
        for path in [
            "/v1/api/openplatform/charge/combo/cycle_audio_resource_package?biz_line=2&cycle_type=3&resource_package_type=7&business=Agent&device_platform=desktop",
            "/backend/account/token_plan/remains_percent?business=Agent&device_platform=desktop",
        ] {
            let response = try await HTTP.get(URL(string: "https://platform.minimax.io" + path)!, headers: headers)
            let object = try? JSONSerialization.jsonObject(with: response.data)
            print("PROBE \(path.prefix(70)) → \(response.status): \(object.map { Self.shape($0) }.map { String($0.prefix(3000)) } ?? "not JSON")")
        }
    }

    /// Renews Antigravity's saved sign-in for real, as the card does once the
    /// saved token has run out, and reads the quota with what came back.
    func testAntigravityRenewalForReal() async throws {
        let clients = AntigravityClients.installed()
        print("PROBE antigravity clients in the installed app: \(clients.count) pairings of \(Set(clients.map(\.id)).count) ids")
        let saved = LocalCredentials.antigravityTokens()
        print("PROBE antigravity saved copies: \(saved.count), with refresh token: \(saved.filter { $0.refreshToken != nil }.count), "
            + "expired: \(saved.map { $0.isExpired() })")
        let refresh = try XCTUnwrap(saved.lazy.compactMap(\.refreshToken).first)
        let env = AntigravityRenewalEnvironment(renewal: AntigravityRenewal())
        let started = Date()
        let token = try await env.renewal.accessToken(refreshToken: refresh, env: env)
        print("PROBE antigravity renewed in \(String(format: "%.1f", Date().timeIntervalSince(started)))s, token differs from saved: \(!saved.contains { $0.accessToken == token })")
        show("antigravity-renewed", try await AntigravityProvider.readCloud(accessToken: token))
        // Antigravity's own files are untouched.
        let after = LocalCredentials.antigravityTokens()
        XCTAssertEqual(after.map(\.accessToken), saved.map(\.accessToken))
        XCTAssertEqual(after.map(\.refreshToken), saved.map(\.refreshToken))
    }

    /// MiniMax Code's signed user-info request, for the account under the card.
    func testMiniMaxAccountForReal() async throws {
        let signIn = try XCTUnwrap(MiniMaxCode.signIn())
        let signing = MiniMaxSigningReader.installed()
        print("PROBE minimax signing read from the app: \(signing != nil)")
        let request = MiniMaxCode.userInfoRequest(region: signIn.region, token: signIn.accessToken, signing: try XCTUnwrap(signing), now: Date())
        let response = try await HTTP.get(request.url, headers: request.headers)
        let object = try? JSONSerialization.jsonObject(with: response.data)
        print("PROBE minimax user/info \(response.status): \(object.map { String(Self.shape($0).prefix(1500)) } ?? "not JSON")")
        let email = MiniMaxCode.userInfo(response.data)?.email
        var masked = "none"
        if let email, let at = email.firstIndex(of: "@") {
            masked = String(email.prefix(1)) + "***" + String(email[at...])
        }
        print("PROBE minimax account: \(masked)")
        if let root = object as? [String: Any], let data = root["data"] as? [String: Any], let user = data["userInfo"] as? [String: Any] {
            for key in ["phone", "subUserName", "name"] {
                let text = user[key] as? String ?? ""
                let digits = text.filter(\.isNumber).count
                let stars = text.filter { $0 == "*" }.count
                let classes = Set(text.map { $0.isNumber ? "9" : $0 == "*" ? "*" : $0.isLetter ? "a" : String($0) }).sorted().joined()
                print("PROBE minimax \(key): length \(text.count), digits \(digits), stars \(stars), characters \(classes)")
            }
        }
    }

    func testMiniMaxRenewalForReal() async throws {
        guard ProcessInfo.processInfo.environment["QUOTABAR_PROBE_RENEW"] == "1" else {
            throw XCTSkip("QUOTABAR_PROBE_RENEW is not set")
        }
        let before = try XCTUnwrap(MiniMaxCode.signIn())
        print("PROBE renew before: generation=\(before.generation) status=\(before.status) expires in \(Int(before.expiresAt.timeIntervalSinceNow / 60)) min")
        let env = MiniMaxCodeEnvironment(mayRenew: true, renewal: MiniMaxCodeRenewal())
        // As if the quota endpoint had turned the current token down.
        let token = try await env.renewal.token(region: before.region, rejected: before.accessToken, env: env)
        XCTAssertNotEqual(token, before.accessToken)
        let after = try XCTUnwrap(MiniMaxCode.signIn())
        print("PROBE renew after: generation=\(after.generation) status=\(after.status) expires in \(Int(after.expiresAt.timeIntervalSinceNow / 60)) min, token changed: \(after.accessToken != before.accessToken)")
        XCTAssertEqual(after.accessToken, token)
        XCTAssertEqual(after.status, "authenticated")
        XCTAssertEqual(after.generation, before.generation + 1)
        let journal = MiniMaxCode.namespace(before.region, authHome: MiniMaxCode.authHome).appendingPathComponent("refresh/auth.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path))
        show("minimax-renewed", try await MiniMaxCode.fetchRemains(region: after.region, token: token, send: HTTP.live))
    }

    /// Qoder's card against center.qoder.sh with the Qoder app's sign-in on
    /// this Mac. Reads the keychain (one macOS "Allow" the first time) and
    /// prints only the plan and the figures, never the token.
    func testQoderWithAppSignIn() async throws {
        guard QoderApp.isInstalled() else { throw XCTSkip("Qoder app not installed") }
        _ = QoderApp.authorize()  // the one allowed keychain dialog
        let state = QoderApp.sessionState()
        print("PROBE qoder session: \(QoderApp.sessionDescription())")
        guard state == .available else { throw XCTSkip("Qoder sign-in not readable (state: \(state))") }
        let provider = QoderProvider()
        print("PROBE qoder source: \(provider.sourceInfo(config: config())?.summary ?? "-")")
        show("qoder", try await provider.fetch(config: config()))
    }
}