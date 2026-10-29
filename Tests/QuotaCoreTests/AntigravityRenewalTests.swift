import XCTest
@testable import QuotaCore
@testable import QuotaModel

/// Antigravity's saved sign-in renewed for QuotaBar's own use, with a
/// scripted token endpoint: nothing here reaches Google.
final class AntigravityRenewalTests: XCTestCase {
    private let right = AntigravityClient(id: "111111111111-rightrightrightrightrightright1234.apps.googleusercontent.com", secret: "GOCSPX-right")
    private let wrong = AntigravityClient(id: "222222222222-wrongwrongwrongwrongwrongwrong1234.apps.googleusercontent.com", secret: "GOCSPX-wrong")

    private func form(_ request: ScriptedNetwork.Request) -> [String: String] {
        Dictionary(uniqueKeysWithValues: request.body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return (parts[0], (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? "")
        })
    }

    /// Google as it answers: the right client gets a token, a client the
    /// token was not issued to is turned away.
    private func google(refused: Bool = false) -> ScriptedNetwork {
        ScriptedNetwork { [right] request in
            let fields = Dictionary(uniqueKeysWithValues: request.body.split(separator: "&").map { pair -> (String, String) in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                return (parts[0], (parts.count > 1 ? parts[1] : "").removingPercentEncoding ?? "")
            })
            if refused { return ScriptedNetwork.json(400, #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#) }
            guard fields["client_id"] == right.id, fields["client_secret"] == right.secret else {
                return ScriptedNetwork.json(401, #"{"error":"invalid_client","error_description":"Unauthorized"}"#)
            }
            return ScriptedNetwork.json(200, #"{"access_token":"ya29.renewed","expires_in":3599,"token_type":"Bearer","scope":"openid"}"#)
        }
    }

    private func environment(_ network: ScriptedNetwork, clients: [AntigravityClient]? = nil, now: @escaping @Sendable () -> Date = { Date() }) -> AntigravityRenewalEnvironment {
        let clients = clients ?? [wrong, right]
        return AntigravityRenewalEnvironment(send: network.send, now: now, clients: { clients }, renewal: AntigravityRenewal())
    }

    func testTheRightClientRenewsAndItsTokenIsReused() async throws {
        let network = google()
        let env = environment(network)
        let token = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
        XCTAssertEqual(token, "ya29.renewed")
        XCTAssertEqual(network.posts.count, 2, "the wrong client first, then the right one")
        let post = try XCTUnwrap(network.posts.last)
        XCTAssertEqual(post.url.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(post.headers["Content-Type"], "application/x-www-form-urlencoded")
        XCTAssertEqual(form(post)["grant_type"], "refresh_token")
        XCTAssertEqual(form(post)["refresh_token"], "1//refresh")

        // Kept in memory while it has time left: no second request.
        _ = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
        XCTAssertEqual(network.posts.count, 2)

        // Once it is thrown away, the client that worked is asked first.
        env.renewal.discard(refreshToken: "1//refresh")
        _ = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
        XCTAssertEqual(network.posts.count, 3)
        XCTAssertEqual(form(network.posts[2])["client_id"], right.id)
    }

    func testARenewedTokenIsRenewedAgainNearItsEnd() async throws {
        let network = google()
        let clock = Clock()
        let env = environment(network, clients: [right], now: { clock.now })
        _ = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
        clock.now = clock.now.addingTimeInterval(3599 - 60)
        _ = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
        XCTAssertEqual(network.posts.count, 2, "a minute left is under the two-minute margin")
    }

    func testARefusedSignInIsSaidAsSuchAndNotSentAgain() async throws {
        let network = google(refused: true)
        let env = environment(network)
        do {
            _ = try await env.renewal.accessToken(refreshToken: "1//revoked", env: env)
            XCTFail()
        } catch AntigravityRenewal.Failure.signInAgain {}
        let sent = network.posts.count
        do {
            _ = try await env.renewal.accessToken(refreshToken: "1//revoked", env: env)
            XCTFail()
        } catch AntigravityRenewal.Failure.signInAgain {}
        XCTAssertEqual(network.posts.count, sent)
    }

    func testANetworkFailureWaitsBeforeTryingAgain() async throws {
        let network = ScriptedNetwork { _ in throw ProviderError.network("offline") }
        let env = environment(network)
        for _ in 0 ..< 2 {
            do {
                _ = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
                XCTFail()
            } catch AntigravityRenewal.Failure.unavailable {}
        }
        XCTAssertEqual(network.posts.count, 1, "offline stops the round, and the cooldown holds the next")
    }

    func testNoClientThatTakesItIsNotASignOut() async throws {
        let network = google()
        let env = environment(network, clients: [wrong])
        do {
            _ = try await env.renewal.accessToken(refreshToken: "1//refresh", env: env)
            XCTFail()
        } catch AntigravityRenewal.Failure.noClient {}
        let none = environment(network, clients: [])
        do {
            _ = try await none.renewal.accessToken(refreshToken: "1//refresh", env: none)
            XCTFail()
        } catch AntigravityRenewal.Failure.noClient {}
    }

    // MARK: The card

    private func saved(expiresIn: TimeInterval, refresh: String?) -> LocalCredentials.AntigravityToken {
        LocalCredentials.AntigravityToken(accessToken: "ya29.saved", expiry: Date().addingTimeInterval(expiresIn), refreshToken: refresh)
    }

    func testASavedTokenWithTimeLeftIsUsedAsItIs() async throws {
        let network = google()
        let token = try await AntigravityProvider.accessToken(
            saved: [saved(expiresIn: 1800, refresh: "1//refresh")], env: environment(network), local: .notRunning)
        XCTAssertEqual(token, "ya29.saved")
        XCTAssertTrue(network.requests.isEmpty)
    }

    func testAnExpiredSavedTokenIsRenewed() async throws {
        let network = google()
        let token = try await AntigravityProvider.accessToken(
            saved: [saved(expiresIn: -600, refresh: "1//refresh")], env: environment(network), local: .notRunning)
        XCTAssertEqual(token, "ya29.renewed")
    }

    func testTheOtherSavedCopyIsTriedWhenTheFirstIsRefused() async throws {
        let network = ScriptedNetwork { request in
            request.body.contains("refresh_token=1%2F%2Fold")
                ? ScriptedNetwork.json(400, #"{"error":"invalid_grant"}"#)
                : ScriptedNetwork.json(200, #"{"access_token":"ya29.from-the-other","expires_in":3599}"#)
        }
        let token = try await AntigravityProvider.accessToken(
            saved: [saved(expiresIn: -60, refresh: "1//old"), saved(expiresIn: -600, refresh: "1//new")],
            env: environment(network, clients: [right]), local: .notRunning)
        XCTAssertEqual(token, "ya29.from-the-other")
    }

    func testWhatTheCardSaysWhenItCannotRenew() async {
        do {
            _ = try await AntigravityProvider.accessToken(
                saved: [saved(expiresIn: -600, refresh: nil)], env: environment(google()), local: .notRunning)
            XCTFail()
        } catch ProviderError.sessionExpired(let hint) {
            XCTAssertEqual(hint, AntigravityProvider.expiredTokenHint(.notRunning))
        } catch { XCTFail("\(error)") }
        do {
            _ = try await AntigravityProvider.accessToken(
                saved: [saved(expiresIn: -600, refresh: "1//revoked")], env: environment(google(refused: true)), local: .notRunning)
            XCTFail()
        } catch ProviderError.sessionExpired(let hint) {
            XCTAssertEqual(hint, AntigravityProvider.signInAgainHint)
        } catch { XCTFail("\(error)") }
    }

    /// Read without the app, the card names the account the app saved its
    /// sign-in for, as the running app's reading does; one that names its
    /// own is left as it is.
    func testTheSavedAccountGoesUnderTheCardsName() {
        let saved = [LocalCredentials.AntigravityToken(accessToken: "a", expiry: nil, refreshToken: "r", email: "me@example.com")]
        XCTAssertEqual(AntigravityProvider.withAccount(UsageSnapshot(windows: []), saved).account, "me@example.com")
        XCTAssertEqual(AntigravityProvider.withAccount(UsageSnapshot(account: "app@example.com", windows: []), saved).account, "app@example.com")
        XCTAssertNil(AntigravityProvider.withAccount(UsageSnapshot(windows: []), []).account)
    }

    // MARK: The saved sign-in and the installed app

    func testTheRefreshTokenIsReadWithTheRest() throws {
        let root: [String: Any] = [
            "token": ["access_token": "ya29.x", "refresh_token": "1//r", "expiry": "2026-10-30T01:00:00.123456+05:00"],
            "auth_method": "consumer", "id_token_email": "me@example.com",
        ]
        let token = try XCTUnwrap(LocalCredentials.antigravityToken(in: root))
        XCTAssertEqual(token.refreshToken, "1//r")
        XCTAssertEqual(token.email, "me@example.com")
        XCTAssertNil(LocalCredentials.antigravityToken(in: ["token": ["access_token": "ya29.x", "refresh_token": " "]])?.refreshToken)
    }

    /// Strings packed end to end, as a Go binary keeps them.
    func testClientsAreReadFromThePackedStrings() {
        let random = "abcdefghijklmnopqrstuvwxyz012345"
        let secretA = "GOCSPX-" + String(repeating: "A", count: 27) + "1"
        let secretB = "GOCSPX-" + String(repeating: "b", count: 27) + "_"
        let text = "gzip9123456789012-\(random).apps.googleusercontent.com\(secretA)nextstring"
            + "xx1234567-\(random).apps.googleusercontent.comtail\(secretB)Z"
            + "GOCSPX-short.apps.googleusercontent.com"
        let clients = AntigravityClients.clients(in: Data(text.utf8))
        let ids = Array(Set(clients.map(\.id))).sorted()
        XCTAssertEqual(ids, [
            "1234567-\(random).apps.googleusercontent.com",
            "123456789012-\(random).apps.googleusercontent.com",
            "9123456789012-\(random).apps.googleusercontent.com",
        ], "digits running on from the string before are offered both ways")
        XCTAssertEqual(Set(clients.map(\.secret)), [secretA, secretB], "a secret is its 35 characters, whatever follows")
        XCTAssertEqual(clients.count, 6)
        XCTAssertEqual(clients.first?.id, "123456789012-\(random).apps.googleusercontent.com", "twelve digits first")
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date()
    var now: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}
