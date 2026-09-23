import CryptoKit
import XCTest
@testable import QuotaCore
import QuotaModel
import QuotaRelay

/// The whole relay against a real quota.run server on this machine: a Mac
/// and a phone joining one account, the owner allowing the phone, readings
/// crossing sealed, a refresh request, and a revoke. Skipped unless
/// `QUOTA_RUN_LOCAL` names the server, started with `QUOTA_RUN_DEV_LOGIN=1`
/// and `QUOTA_RUN_ORIGIN` equal to it, e.g.
/// `QUOTA_RUN_LOCAL=http://localhost:8788 swift test --filter RelayLiveTests`.
final class RelayLiveTests: XCTestCase {
    fileprivate var origin: URL!
    private var base: URL { origin.appendingPathComponent("api/v1") }
    /// The web session's cookies, kept by hand: a private cookie store
    /// does not hold on to localhost's.
    private var cookies: [String: String] = [:]

    override func setUpWithError() throws {
        guard let raw = ProcessInfo.processInfo.environment["QUOTA_RUN_LOCAL"], let url = URL(string: raw) else {
            throw XCTSkip("QUOTA_RUN_LOCAL is not set")
        }
        origin = url
    }

    /// The owner on quota.run's pages: a web session, as the connect page has.
    fileprivate func web(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> (Int, [String: Any]) {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue(origin.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        request.httpShouldHandleCookies = false
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as! HTTPURLResponse
        let headers = http.allHeaderFields as? [String: String] ?? [:]
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!) {
            cookies[cookie.name] = cookie.value
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, json)
    }

    private func signUp() async throws -> String {
        let name = "e2e" + String(UUID().uuidString.prefix(8)).lowercased()
        let (signedIn, _) = try await web("POST", "auth/dev", ["email": "\(name)@example.com"])
        XCTAssertEqual(signedIn, 200)
        let (created, reply) = try await web("POST", "signup", ["username": name, "displayName": "E2E", "region": "global"])
        XCTAssertEqual(created, 201, "\(reply)")
        return name
    }

    private func approve(_ userCode: String) async throws {
        let (status, reply) = try await web("POST", "connect/\(userCode)/approve")
        XCTAssertEqual(status, 200, "\(reply)")
    }

    private func readings(used: Double) -> CloudReadings {
        CloudReadings(
            deviceID: "icloud-studio", deviceName: "Studio", appVersion: "0.6.0", language: "zh", updatedAt: Date(),
            providers: [CloudReadings.Entry(
                id: "claude",
                snapshot: UsageSnapshot(planName: "Max", windows: [UsageWindow(title: "5h", usedPercent: used)], fetchedAt: Date()),
                error: nil)])
    }

    func testAPhoneOnAnotherICloudAccountReadsTheMacThroughQuotaRun() async throws {
        _ = try await signUp()

        // The Mac joins as it does today, and reuses its key for the relay.
        let macSigner = SoftwareRunSigner()
        let runClient = QuotaRunClient(base: base, signer: macSigner)
        let macStart = try await runClient.connectStart(deviceName: "Studio", appVersion: "0.6.0")
        try await approve(macStart.userCode)
        guard case let .approved(registration) = try await runClient.connectPoll(requestId: macStart.requestId) else {
            return XCTFail("the Mac was not approved")
        }
        let mac = RelayClient(base: base, signer: macSigner, deviceID: registration.deviceId)

        // The phone joins the same account.
        let phoneKeys = (signing: P256.Signing.PrivateKey(), agreement: P256.KeyAgreement.PrivateKey())
        let joining = RelayClient(base: base, signer: SoftwareRunSigner(key: phoneKeys.signing))
        let phoneStart = try await joining.connectStart(deviceName: "iPhone", appVersion: "0.6.0", chinese: true)
        try await approve(phoneStart.userCode)
        let polled = try await joining.connectPoll(requestID: phoneStart.requestId)
        XCTAssertEqual(polled.status, "approved")
        let phoneID = try XCTUnwrap(polled.deviceId)
        let phone = RelayClient(base: base, signer: SoftwareRunSigner(key: phoneKeys.signing), deviceID: phoneID)
        try await phone.putAgreementKey(phoneKeys.agreement.publicKey.x963Representation)

        // The Mac sees the phone, with the key it will seal to and the code
        // the owner compares.
        let listed = try await mac.phones()
        let entry = try XCTUnwrap(listed.first { $0.deviceId == phoneID })
        XCTAssertNil(entry.grantedAt)
        let agreementKey = try XCTUnwrap(entry.agreementKey)
        XCTAssertEqual(
            SyncCrypto.safetyCode(for: try XCTUnwrap(Base64URL.decode(agreementKey))),
            SyncCrypto.safetyCode(for: phoneKeys.agreement.publicKey.x963Representation))

        // Before the owner allows it, the phone sees the Mac and nothing it can open.
        let before = try await phone.macs()
        guard case .waiting = RelayReadings.open(try XCTUnwrap(before.first), agreementKey: phoneKeys.agreement, phoneID: phoneID)
        else { return XCTFail("expected waiting") }

        // Allowed: the key sealed to the phone, then readings sealed with it.
        let key = SyncCrypto.newKey()
        let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: try XCTUnwrap(Base64URL.decode(agreementKey)))
        try await mac.grant(
            SyncCrypto.wrap(key, for: publicKey, macID: registration.deviceId, phoneID: phoneID), to: phoneID,
            agreementKey: agreementKey)
        try await mac.putReadings(RelayReadings.seal(readings(used: 37), key: key, macID: registration.deviceId))

        let after = try await phone.macs()
        guard case let .readings(opened) = RelayReadings.open(try XCTUnwrap(after.first), agreementKey: phoneKeys.agreement, phoneID: phoneID)
        else { return XCTFail("the phone could not open the Mac's readings") }
        XCTAssertEqual(opened.providers.first?.snapshot?.windows.first?.usedPercent, 37)

        // "Refresh now" from the phone reaches the Mac.
        try await phone.requestRefresh()
        let request = try await mac.latestRefreshRequest()
        XCTAssertEqual(request.from, "iPhone")
        XCTAssertNotNil(request.requestedAt)

        // Revoked, and the key replaced: the next readings do not open.
        try await mac.revoke(phoneID)
        try await mac.putReadings(RelayReadings.seal(readings(used: 50), key: SyncCrypto.newKey(), macID: registration.deviceId))
        let revoked = try await phone.macs()
        guard case .waiting = RelayReadings.open(try XCTUnwrap(revoked.first), agreementKey: phoneKeys.agreement, phoneID: phoneID)
        else { return XCTFail("expected waiting after the revoke") }

        // Signed out: the Mac no longer lists it.
        try await phone.disconnect()
        let remaining = try await mac.phones()
        XCTAssertFalse(remaining.contains { $0.deviceId == phoneID })
    }
}

extension RelayLiveTests {
    /// The phone can delete the whole account it joined, as App Review
    /// requires of an app that creates accounts; the server forgets it.
    func testThePhoneDeletesTheAccount() async throws {
        _ = try await signUpForScenario()
        let signing = P256.Signing.PrivateKey()
        let joining = RelayClient(base: origin.appendingPathComponent("api/v1"), signer: SoftwareRunSigner(key: signing))
        let start = try await joining.connectStart(deviceName: "iPhone", appVersion: "1.0.0", chinese: true)
        try await approveForScenario(start.userCode)
        let polled = try await joining.connectPoll(requestID: start.requestId)
        let phone = RelayClient(
            base: origin.appendingPathComponent("api/v1"), signer: SoftwareRunSigner(key: signing),
            deviceID: try XCTUnwrap(polled.deviceId))
        _ = try await phone.macs()
        try await phone.deleteAccount()
        do {
            _ = try await phone.macs()
            XCTFail("the deleted account's phone still reads")
        } catch let error as RelayError {
            XCTAssertEqual(error.code, "unknown_device")
        }
    }
}

/// A Mac for trying the phone app by hand against a local server: it joins
/// an account, approves the phone's connection code (read from the server's
/// log, where the approval page's address lands), allows the phone after a
/// pause, and answers "refresh now". Runs only with `QUOTA_RUN_SCENARIO`
/// set to the server's log file.
final class RelayScenario: XCTestCase {
    func testPlayTheMacForAPhone() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["QUOTA_RUN_LOCAL"], let origin = URL(string: raw), let log = env["QUOTA_RUN_SCENARIO"] else {
            throw XCTSkip("QUOTA_RUN_SCENARIO is not set")
        }
        let live = RelayLiveTests()
        try live.setUpWithError()
        _ = origin
        _ = try await live.signUpForScenario()
        let base = origin.appendingPathComponent("api/v1")
        let signer = SoftwareRunSigner()
        let runClient = QuotaRunClient(base: base, signer: signer)
        let start = try await runClient.connectStart(deviceName: "Studio", appVersion: "0.6.0")
        try await live.approveForScenario(start.userCode)
        guard case let .approved(registration) = try await runClient.connectPoll(requestId: start.requestId) else {
            return XCTFail("the Mac was not approved")
        }
        let macID = registration.deviceId
        let mac = RelayClient(base: base, signer: signer, deviceID: macID)
        let key = SyncCrypto.newKey()
        var approved: Set<String> = [start.userCode]
        var firstSeen: [String: Date] = [:]
        var lastRequest: Double?
        var used = 12.0
        print("SCENARIO: Mac \(macID) ready")

        func upload() async throws {
            let readings = CloudReadings(
                deviceID: "icloud-studio", deviceName: "Studio", deviceModel: "Mac Studio (2025)", appVersion: "0.6.0",
                language: "zh", updatedAt: Date(), refreshSeconds: 300,
                providers: [
                    CloudReadings.Entry(
                        id: "claude",
                        snapshot: UsageSnapshot(planName: "Max", windows: [
                            UsageWindow(title: "5h", usedPercent: used, resetsAt: Date().addingTimeInterval(7200), windowSeconds: 18_000),
                            UsageWindow(title: "7d", usedPercent: used / 2, resetsAt: Date().addingTimeInterval(200_000), windowSeconds: 604_800),
                        ], fetchedAt: Date()),
                        error: nil),
                    CloudReadings.Entry(
                        id: "codex",
                        snapshot: UsageSnapshot(planName: "Pro", windows: [
                            UsageWindow(title: "5h", usedPercent: 64, resetsAt: Date().addingTimeInterval(3000), windowSeconds: 18_000),
                        ], fetchedAt: Date()),
                        error: nil),
                ])
            try await mac.putReadings(RelayReadings.seal(readings, key: key, macID: macID))
            print("SCENARIO: uploaded, claude 5h used \(used)")
        }

        let deadline = Date().addingTimeInterval(Double(env["QUOTA_RUN_SCENARIO_SECONDS"] ?? "600") ?? 600)
        while Date() < deadline {
            // The phone's approval page, as the server logged its address.
            let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") where line.contains("connect?code=") {
                guard let range = line.range(of: #"code=[A-Za-z0-9-]+"#, options: .regularExpression) else { continue }
                let code = String(line[range].dropFirst(5)).removingPercentEncoding ?? ""
                guard !approved.contains(code) else { continue }
                approved.insert(code)
                try? await live.approveForScenario(code)
                print("SCENARIO: approved the phone's code \(code)")
            }
            for phone in try await mac.phones() where phone.grantedAt == nil {
                guard let encoded = phone.agreementKey, let raw = Base64URL.decode(encoded) else { continue }
                let seen = firstSeen[phone.deviceId] ?? Date()
                firstSeen[phone.deviceId] = seen
                print("SCENARIO: \(phone.name) waiting, code \(SyncCrypto.safetyCode(for: raw))")
                guard Date().timeIntervalSince(seen) > 25 else { continue }
                let publicKey = try P256.KeyAgreement.PublicKey(x963Representation: raw)
                try await mac.grant(
                    SyncCrypto.wrap(key, for: publicKey, macID: macID, phoneID: phone.deviceId), to: phone.deviceId,
                    agreementKey: encoded)
                print("SCENARIO: allowed \(phone.name)")
                try await upload()
            }
            if let request = try? await mac.latestRefreshRequest(), let at = request.requestedAt, at != lastRequest {
                lastRequest = at
                used += 7
                print("SCENARIO: refresh asked by \(request.from ?? "?")")
                try await Task.sleep(for: .seconds(3))
                try await upload()
            }
            try await Task.sleep(for: .seconds(3))
        }
    }
}

extension RelayLiveTests {
    func signUpForScenario() async throws -> String {
        let name = ProcessInfo.processInfo.environment["QUOTA_RUN_SCENARIO_USER"]
            ?? "e2e" + String(UUID().uuidString.prefix(8)).lowercased()
        _ = try await web("POST", "auth/dev", ["email": "\(name)@example.com"])
        _ = try await web("POST", "signup", ["username": name, "displayName": "Phone Owner", "region": "global"])
        return name
    }

    func approveForScenario(_ code: String) async throws {
        let (status, reply) = try await web("POST", "connect/\(code)/approve")
        if status != 200 { print("SCENARIO: approve \(code) → \(status) \(reply)") }
    }
}
