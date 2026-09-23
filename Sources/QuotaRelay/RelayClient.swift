import Foundation

// MARK: - The relay endpoints on quota.run

/// One call's failure as quota.run words it: `{"error": code, "message": …}`.
public struct RelayError: LocalizedError, Sendable, Equatable {
    public var status: Int
    public var code: String
    public var message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message.isEmpty ? code : message }
}

/// Signed calls to the parts of quota.run both devices use: joining an
/// account by a connection code (the phone; the Mac has its own client for
/// that and for everything else), and the `/sync/*` relay. The Mac passes the
/// signer and device id it already has from joining Quota Run.
public struct RelayClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (status: Int, data: Data)

    public static let productionBase = URL(string: "https://quota.run/api/v1")!

    public var base: URL
    public var signer: RunSigner
    /// Absent until quota.run approves the connection.
    public var deviceID: String?
    public var transport: Transport
    public var clock: @Sendable () -> Date

    public init(
        base: URL = RelayClient.productionBase,
        signer: RunSigner,
        deviceID: String? = nil,
        transport: @escaping Transport = RelayClient.urlSession,
        clock: @escaping @Sendable () -> Date = { Date() })
    {
        self.base = base
        self.signer = signer
        self.deviceID = deviceID
        self.transport = transport
        self.clock = clock
    }

    public static let urlSession: Transport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    // MARK: Joining an account (the phone)

    public struct ConnectStart: Decodable, Sendable {
        public var requestId: String
        public var userCode: String
        public var verifyURL: URL
        public var expiresAt: Double
        public var interval: Double
    }

    public struct ConnectPoll: Decodable, Sendable {
        public struct User: Decodable, Sendable {
            public var username: String
            public var displayName: String
        }
        public var status: String
        public var user: User?
        public var deviceId: String?
    }

    public func connectStart(deviceName: String, appVersion: String, chinese: Bool) async throws -> ConnectStart {
        struct Body: Encodable {
            var publicKey: String, deviceName: String, platform = "ios", appVersion: String, lang: String
        }
        let body = Body(
            publicKey: Base64URL.encode(signer.publicKeyX963), deviceName: deviceName,
            appVersion: appVersion, lang: chinese ? "zh" : "en")
        return try await call("POST", "/connect/start", body: body, anonymous: true)
    }

    public func connectPoll(requestID: String) async throws -> ConnectPoll {
        struct Body: Encodable { var requestId: String, publicKey: String }
        return try await call(
            "POST", "/connect/poll",
            body: Body(requestId: requestID, publicKey: Base64URL.encode(signer.publicKeyX963)), anonymous: true)
    }

    // MARK: The Mac's side

    public struct Phone: Decodable, Sendable, Equatable, Identifiable {
        public var deviceId: String
        public var name: String
        public var createdAt: Double
        public var lastSeenAt: Double?
        /// The phone's HPKE public key (X9.63), once it has sent one.
        public var agreementKey: String?
        /// When this Mac last sealed its key to the phone; nil when it has not.
        public var grantedAt: Double?

        public var id: String { deviceId }
    }

    public func putReadings(_ blob: Data) async throws {
        struct Body: Encodable { var blob: String }
        let _: Ignored = try await call("PUT", "/sync/readings", body: Body(blob: Base64URL.encode(blob)))
    }

    public func phones() async throws -> [Phone] {
        struct Reply: Decodable { var phones: [Phone] }
        let reply: Reply = try await call("GET", "/sync/phones")
        return reply.phones
    }

    public func grant(_ wrapped: Data, to phoneID: String, agreementKey: String) async throws {
        struct Body: Encodable { var wrapped: String, agreementKey: String }
        let _: Ignored = try await call(
            "PUT", "/sync/grants/\(phoneID)", body: Body(wrapped: Base64URL.encode(wrapped), agreementKey: agreementKey))
    }

    public func revoke(_ phoneID: String) async throws {
        let _: Ignored? = try await callAllowingEmpty("DELETE", "/sync/grants/\(phoneID)")
    }

    public struct LatestRequest: Decodable, Sendable {
        public var requestedAt: Double?
        public var from: String?
    }

    public func latestRefreshRequest() async throws -> LatestRequest {
        try await call("GET", "/sync/refresh")
    }

    // MARK: The phone's side

    public struct Mac: Decodable, Sendable {
        public var deviceId: String
        public var name: String
        public var appVersion: String?
        public var updatedAt: Double?
        /// The sealed readings; nil before the Mac first uploads.
        public var blob: String?
        /// The Mac's sync key sealed to this phone; nil until the owner allows it on the Mac.
        public var grant: String?
    }

    public func macs() async throws -> [Mac] {
        struct Reply: Decodable { var macs: [Mac] }
        let reply: Reply = try await call("GET", "/sync/readings")
        return reply.macs
    }

    public func putAgreementKey(_ x963: Data) async throws {
        struct Body: Encodable { var publicKey: String }
        let _: Ignored = try await call("PUT", "/sync/agreement-key", body: Body(publicKey: Base64URL.encode(x963)))
    }

    public func requestRefresh() async throws {
        let _: Ignored = try await call("POST", "/sync/refresh")
    }

    /// Takes this device off the account; what the server held for it goes
    /// with it.
    public func disconnect() async throws {
        let _: Ignored? = try await callAllowingEmpty("DELETE", "/devices/current")
    }

    /// Deletes the whole Quota Run account this device is on — profile,
    /// runs, every device and everything relayed — not only this device.
    public func deleteAccount() async throws {
        let _: Ignored? = try await callAllowingEmpty("DELETE", "/account")
    }

    // MARK: Signing and sending

    private struct Ignored: Decodable {}
    private struct Nothing: Encodable {}

    private func call<Reply: Decodable>(
        _ method: String, _ endpoint: String, body: (some Encodable)? = Nothing?.none, anonymous: Bool = false)
        async throws -> Reply
    {
        let data = try await send(method, endpoint, body: body.map { try Self.encoder.encode($0) }, anonymous: anonymous)
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw RelayError(status: 200, code: "bad_response", message: "quota.run answered in a form this app does not read.")
        }
    }

    private func callAllowingEmpty<Reply: Decodable>(_ method: String, _ endpoint: String) async throws -> Reply? {
        let data = try await send(method, endpoint, body: nil, anonymous: false)
        return data.isEmpty ? nil : try? JSONDecoder().decode(Reply.self, from: data)
    }

    private func send(_ method: String, _ endpoint: String, body: Data?, anonymous: Bool) async throws -> Data {
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text + endpoint) else { throw RelayError(status: 0, code: "bad_url", message: endpoint) }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let timestamp = Int(clock().timeIntervalSince1970)
        var generator = SystemRandomNumberGenerator()
        let nonce = Base64URL.encode(Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &generator) }))
        let canonical = RunCanonical.string(method: method, path: path, timestamp: timestamp, nonce: nonce, body: body)
        let signature = try signer.signature(for: Data(canonical.utf8))

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        request.setValue(String(timestamp), forHTTPHeaderField: "X-Quota-Timestamp")
        request.setValue(nonce, forHTTPHeaderField: "X-Quota-Nonce")
        request.setValue(Base64URL.encode(signature), forHTTPHeaderField: "X-Quota-Signature")
        if let deviceID, !anonymous { request.setValue(deviceID, forHTTPHeaderField: "X-Quota-Device") }

        let (status, data) = try await transport(request)
        guard (200..<300).contains(status) else {
            struct Wire: Decodable { var error: String?, message: String? }
            let wire = try? JSONDecoder().decode(Wire.self, from: data)
            throw RelayError(status: status, code: wire?.error ?? "http_\(status)", message: wire?.message ?? "")
        }
        return data
    }
}
