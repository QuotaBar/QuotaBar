import CryptoKit
import Foundation

// MARK: - ZCode's sign-in (~/.zcode/v2/credentials.json)

/// The z.ai (or bigmodel.cn) account ZCode is signed in to.
///
/// ZCode keeps its sign-in in `~/.zcode/v2/credentials.json`, one entry per
/// credential, each value sealed as `enc:v1:<iv>.<tag>.<ciphertext>`
/// (base64url, AES-256-GCM). The key is the SHA-256 of a string ZCode makes
/// from this Mac itself — `zcode-credential-fallback:<platform>:<home>:<user>`,
/// or `ZCODE_CREDENTIAL_SECRET` when that is set — so the sealing keeps the
/// file from being read at a glance, not from this user's own apps: QuotaBar
/// opens it the way ZCode does. A value without the prefix is stored plain.
///
/// The token is the one z.ai's own console signs in with; ZCode sends it as
/// `Authorization: Bearer` to z.ai's account endpoints, and the Coding Plan
/// quota endpoint takes it the same way. Only read, never written.
public struct ZCodeSignIn: Sendable, Equatable {
    public enum Family: String, Sendable {
        case zai
        case bigmodel
    }

    public let family: Family
    public let token: String
    /// The token's `exp`, when it is a JWT that carries one.
    public let expiresAt: Date?

    public func isExpired(now: Date = Date()) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
}

public enum ZCode {
    static let sealPrefix = "enc:v1:"

    public static var credentialsFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".zcode/v2/credentials.json")
    }

    /// The sign-in for one family, from ZCode's file on this Mac.
    public static func signIn(family: ZCodeSignIn.Family = .zai) -> ZCodeSignIn? {
        signIn(file: credentialsFile, family: family, secret: secret())
    }

    static func signIn(file: URL, family: ZCodeSignIn.Family, secret: String) -> ZCodeSignIn? {
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sealed = root["oauth:\(family.rawValue):access_token"] as? String,
              let opened = open(sealed, secret: secret)
        else { return nil }
        let token = opened.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^Bearer\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
        guard !token.isEmpty else { return nil }
        let expiry = (LocalCredentials.jwtPayload(token)?["exp"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue) }
        return ZCodeSignIn(family: family, token: token, expiresAt: expiry)
    }

    /// What ZCode derives its key from (`defaultCredentialSecret`): Node's
    /// `os.homedir()` and `os.userInfo().username`, on macOS `darwin`.
    static func secret(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        user: String = NSUserName()) -> String
    {
        if let given = environment["ZCODE_CREDENTIAL_SECRET"], !given.isEmpty { return given }
        return "zcode-credential-fallback:darwin:\(home):\(user)"
    }

    /// One stored value, opened; nil when it is sealed with another key or
    /// is not well formed.
    static func open(_ value: String, secret: String) -> String? {
        guard value.hasPrefix(sealPrefix) else { return value }
        let parts = value.dropFirst(sealPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let iv = base64URL(parts[0]), iv.count == 12,
              let tag = base64URL(parts[1]), tag.count == 16,
              let body = base64URL(parts[2]),
              let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: body, tag: tag),
              let plain = try? AES.GCM.open(box, using: key(secret))
        else { return nil }
        return String(data: plain, encoding: .utf8)
    }

    /// Seals a value as ZCode does, for tests that need a file of its kind.
    static func seal(_ value: String, secret: String) -> String? {
        guard let box = try? AES.GCM.seal(Data(value.utf8), using: key(secret)) else { return nil }
        return sealPrefix + [Data(box.nonce), box.tag, box.ciphertext].map(base64URLString).joined(separator: ".")
    }

    private static func key(_ secret: String) -> SymmetricKey {
        SymmetricKey(data: SHA256.hash(data: Data(secret.utf8)))
    }

    static func base64URL(_ text: Substring) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    static func base64URLString(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
