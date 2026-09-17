import CryptoKit
import Darwin
import Foundation

// MARK: - Editions

/// Kimi Code runs as two services with separate accounts: the China edition
/// on kimi.com and the global one on kimi.ai. A token, key or cookie belongs
/// to one of them.
public enum KimiEdition: String, Sendable, CaseIterable, Codable {
    case china
    case global

    /// Kimi Code's `mainland-cn` and `global` region profiles.
    public var apiBase: URL {
        switch self {
        case .china: URL(string: "https://api.kimi.com/coding/v1")!
        case .global: URL(string: "https://api.kimi.ai/coding/v1")!
        }
    }

    public var oauthHost: String {
        switch self {
        case .china: "https://auth.kimi.com"
        case .global: "https://auth.kimi.ai"
        }
    }

    public var site: String {
        switch self {
        case .china: "kimi.com"
        case .global: "kimi.ai"
        }
    }

    public var usagesURL: URL { apiBase.appendingPathComponent("usages") }

    /// Where the plan and API keys are managed; Kimi Code's own help menu
    /// links here.
    public var consoleURL: URL { URL(string: "https://www.\(site)/code/console")! }

    /// For the plan chip.
    public var label: String {
        switch self {
        case .china: L10n.t("China", "国内版")
        case .global: L10n.t("Global", "国际版")
        }
    }

    /// For Settings, with the site that tells the two apart.
    public var longLabel: String {
        L10n.t("\(label) (\(site))", "\(label)（\(site)）")
    }

    /// Named after the Code API host, which is where the account lives.
    static func forAPIHost(_ host: String?) -> KimiEdition {
        host == "api.kimi.ai" ? .global : .china
    }
}

/// Where a Kimi reading came from, as `UsageSnapshot.source` keeps it: a
/// stable id, worded only when shown.
public enum KimiSource: String, Sendable, CaseIterable {
    /// The Kimi Code app or CLI's sign-in on this Mac.
    case signIn
    /// The older Python CLI's sign-in in `~/.kimi`.
    case legacySignIn
    case apiKey
    case cookie

    public var label: String {
        switch self {
        case .signIn: L10n.t("Kimi Code sign-in", "Kimi Code 本机登录")
        case .legacySignIn: L10n.t("Older Kimi CLI sign-in", "旧版 Kimi CLI 登录")
        case .apiKey: L10n.t("API key", "API Key")
        case .cookie: L10n.t("kimi-auth cookie", "kimi-auth Cookie")
        }
    }
}

// MARK: - Credential files

/// One of the credential files Kimi Code may sign in to: the name it saves
/// under and the hosts that name stands for.
public struct KimiCodeSlot: Sendable, Equatable {
    public let storageName: String
    public let oauthHost: String
    public let baseURL: URL

    public var edition: KimiEdition { KimiEdition.forAPIHost(baseURL.host) }
}

/// A credential file as Kimi Code's `tokenFromWire` reads it.
struct KimiCodeTokenFile {
    let root: [String: Any]
    /// The top-level keys in the order the file has them, so a rewrite keeps
    /// any key Kimi Code does not know in its place.
    let keyOrder: [String]

    var accessToken: String { root["access_token"] as? String ?? "" }
    var refreshToken: String { root["refresh_token"] as? String ?? "" }
    /// A JSON number, or 0 — which Kimi Code takes as "never renew".
    var expiresAtField: Double { Self.jsonNumber(root["expires_at"]) ?? 0 }
    var expiresIn: Double { Self.jsonNumber(root["expires_in"]) ?? 0 }
    var scope: String { root["scope"] as? String ?? "" }
    var tokenType: String { root["token_type"] as? String ?? "" }

    /// Blanked by Kimi Code after a refused renewal: signed out.
    var isRevoked: Bool { accessToken.isEmpty }

    /// When the access token runs out: the file's figure, else the token's
    /// own `exp`. nil for neither.
    var expiresAt: Date? {
        if expiresAtField > 0 { return Dates.parseEpoch(expiresAtField) }
        return LocalCredentials.jwtPayload(accessToken)
            .flatMap { QwenProvider.number($0["exp"]) }
            .flatMap(Dates.parseEpoch)
    }

    /// When the refresh token runs out, from its own `exp`; nil when it
    /// carries none.
    var refreshExpiresAt: Date? {
        LocalCredentials.jwtPayload(refreshToken)
            .flatMap { QwenProvider.number($0["exp"]) }
            .flatMap(Dates.parseEpoch)
    }

    enum Read {
        case missing
        /// There, but not a JSON object — Kimi Code reads that as missing
        /// too. QuotaBar writes over it only with a renewal the server has
        /// already granted (`KimiCodeRenewal.saveDecision`).
        case unreadable
        case token(KimiCodeTokenFile)
    }

    static func read(_ url: URL) -> Read {
        guard let data = try? Data(contentsOf: url) else {
            return FileManager.default.fileExists(atPath: url.path) ? .unreadable : .missing
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unreadable }
        return .token(KimiCodeTokenFile(root: root, keyOrder: topLevelKeys(String(decoding: data, as: UTF8.self))))
    }

    /// `typeof value === "number"`: numbers, not strings and not booleans.
    static func jsonNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// The object's own keys, first appearance first. Only as good as the
    /// JSON is valid, which `JSONSerialization` has already checked.
    static func topLevelKeys(_ text: String) -> [String] {
        var keys: [String] = []
        var depth = 0
        var index = text.startIndex
        var expectingKey = false
        while index < text.endIndex {
            let character = text[index]
            switch character {
            case "{", "[":
                depth += 1
                expectingKey = depth == 1 && character == "{"
            case "}", "]":
                depth -= 1
            case ",":
                expectingKey = depth == 1
            case "\"":
                var end = text.index(after: index)
                var raw = ""
                while end < text.endIndex, text[end] != "\"" {
                    if text[end] == "\\" {
                        raw.append(text[end])
                        end = text.index(after: end)
                        guard end < text.endIndex else { break }
                    }
                    raw.append(text[end])
                    end = text.index(after: end)
                }
                if depth == 1, expectingKey,
                   let decoded = try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8), options: .fragmentsAllowed) as? String
                {
                    keys.append(decoded)
                    expectingKey = false
                }
                index = end < text.endIndex ? end : text.index(before: text.endIndex)
            default:
                break
            }
            index = text.index(after: index)
        }
        return keys
    }

    // MARK: Writing

    /// The six keys in Kimi Code's order, then any others the file had, as
    /// `JSON.stringify(token, null, 2) + "\n"` prints them — byte for byte
    /// what Kimi Code itself writes when there are no others.
    static func render(
        accessToken: String,
        refreshToken: String,
        expiresAt: Double,
        scope: String,
        tokenType: String,
        expiresIn: Double,
        keeping previous: KimiCodeTokenFile? = nil) -> String
    {
        var fields: [(String, String)] = [
            ("access_token", jsString(accessToken)),
            ("refresh_token", jsString(refreshToken)),
            ("expires_at", jsNumber(expiresAt)),
            ("scope", jsString(scope)),
            ("token_type", jsString(tokenType)),
            ("expires_in", jsNumber(expiresIn)),
        ]
        if let previous {
            let known = Set(fields.map(\.0))
            let ordered = previous.keyOrder + previous.root.keys.sorted()
            var seen = Set<String>()
            for key in ordered where !known.contains(key) && seen.insert(key).inserted {
                guard let value = previous.root[key] else { continue }
                fields.append((key, jsValue(value, indent: 2)))
            }
        }
        let body = fields.map { "  \(jsString($0.0)): \($0.1)" }.joined(separator: ",\n")
        return "{\n\(body)\n}\n"
    }

    /// `JSON.stringify` for a string: `"`, `\` and control characters
    /// escaped, nothing else — not `/`, not non-ASCII.
    static func jsString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// A JavaScript number as `JSON.stringify` prints it: whole numbers
    /// without a fraction (`900`, not `900.0`).
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == 0 { return "0" }
        if value == value.rounded(), abs(value) < 1e21 { return String(format: "%.0f", value) }
        var text = "\(value)"
        // Swift writes 1e-07 and 1e+21 where JavaScript writes 1e-7 and 1e+21.
        if let range = text.range(of: #"e([+-])0*(\d)"#, options: .regularExpression) {
            let match = String(text[range])
            let sign = match.dropFirst().first.map(String.init) ?? "+"
            text.replaceSubrange(range, with: "e\(sign)\(match.last.map(String.init) ?? "")")
        }
        return text
    }

    /// Any JSON value, indented as `JSON.stringify(_, null, 2)` would at
    /// this depth. Nested objects keep sorted keys: their order is lost in
    /// parsing and nothing reads it.
    static func jsValue(_ value: Any, indent: Int) -> String {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch value {
        case is NSNull:
            return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return jsNumber(number.doubleValue)
        case let string as String:
            return jsString(string)
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            return "[\n" + array.map { inner + jsValue($0, indent: indent + 2) }.joined(separator: ",\n") + "\n\(pad)]"
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            return "{\n" + object.keys.sorted().map { "\(inner)\(jsString($0)): \(jsValue(object[$0]!, indent: indent + 2))" }
                .joined(separator: ",\n") + "\n\(pad)}"
        default:
            return "null"
        }
    }

    /// Kimi Code's `FileTokenStorage.save`: the directory kept at 0700, a
    /// temporary file beside the target, written in full and synced, made
    /// 0600, then renamed over the target — never a half-written file.
    static func write(_ text: String, to target: URL) throws {
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        var random = [UInt8](repeating: 0, count: 4)
        _ = SecRandomCopyBytes(kSecRandomDefault, random.count, &random)
        let suffix = random.map { String(format: "%02x", $0) }.joined()
        let temporary = directory.appendingPathComponent("\(target.lastPathComponent).tmp.\(getpid()).\(suffix)").path

        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let bytes = Array(text.utf8)
        var written = 0
        var failure: Int32 = 0
        while written < bytes.count {
            let count = bytes[written...].withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                failure = errno
                break
            }
            written += count
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        close(descriptor)
        if failure == 0, chmod(temporary, 0o600) != 0 { failure = errno }
        if failure == 0, rename(temporary, target.path) != 0 { failure = errno }
        if failure != 0 {
            unlink(temporary)
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
    }
}

// MARK: - config.toml

/// Which sign-in Kimi Code uses, from `~/.kimi-code/config.toml`:
///
///     [providers."managed:kimi-code"]
///     base_url = "https://api.kimi.ai/coding/v1"
///     [providers."managed:kimi-code".oauth]
///     key = "oauth/kimi-code-env-0e4f99c69cc27850"
///     oauth_host = "https://auth.kimi.ai"
///
/// A China sign-in writes `key = "oauth/kimi-code"` and no `oauth_host`.
/// The `oauth` table may also be written inline. Only read, with just
/// enough TOML for these lines.
enum KimiCodeConfig {
    struct ManagedSignIn: Equatable {
        let storageName: String
        let oauthHost: String?
        let baseURL: String?
    }

    static func managedSignIn(codeHome: URL) -> ManagedSignIn? {
        guard let text = try? String(contentsOf: codeHome.appendingPathComponent("config.toml"), encoding: .utf8) else {
            return nil
        }
        return managedSignIn(toml: text)
    }

    /// The slot Kimi Code signs in with, when it is one of the known ones and
    /// the hosts config.toml names are the ones that slot stands for. Any
    /// other hosts are none of QuotaBar's business.
    /// Kimi Code says it is signed out: config.toml is there and has no Kimi
    /// Code sign-in in it — its logout removes `managed:kimi-code` along
    /// with the credential file in use, and leaves files from an earlier
    /// edition behind. Only when the name is gone from the file altogether,
    /// so a table this reader cannot follow never counts as signed out; and
    /// never without config.toml, which older Kimi Code did not write.
    static func saysSignedOut(codeHome: URL) -> Bool {
        guard let text = try? String(contentsOf: codeHome.appendingPathComponent("config.toml"), encoding: .utf8) else {
            return false
        }
        return managedSignIn(toml: text) == nil && !text.contains("managed:kimi-code")
    }

    static func activeSlot(codeHome: URL) -> KimiCodeSlot? {
        guard let signIn = managedSignIn(codeHome: codeHome),
              let slot = LocalCredentials.kimiCodeSlots[signIn.storageName]
        else { return nil }
        let oauthHost = trimmedEndpoint(signIn.oauthHost ?? KimiEdition.china.oauthHost)
        guard oauthHost == slot.oauthHost else { return nil }
        if let base = signIn.baseURL, trimmedEndpoint(base) != slot.baseURL.absoluteString { return nil }
        return slot
    }

    static func trimmedEndpoint(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    static func managedSignIn(toml: String) -> ManagedSignIn? {
        let provider = ["providers", "managed:kimi-code"]
        var table: [String] = []
        var values: [[String]: String] = [:]
        for rawLine in toml.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                let arrayTable = line.hasPrefix("[[")
                let inner = line.drop { $0 == "[" }.reversed().drop { $0 == "]" }.reversed()
                table = keyPath(String(inner)) ?? ["?"]
                if arrayTable { table.append("[]") }
                continue
            }
            guard let equals = firstUnquoted("=", in: line) else { continue }
            guard let key = keyPath(String(line[..<equals])) else { continue }
            let rawValue = String(line[line.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            let path = table + key
            if rawValue.hasPrefix("{") {
                for (innerKey, innerValue) in inlineTable(rawValue) {
                    if let string = stringValue(innerValue) { values[path + innerKey] = string }
                }
            } else if let string = stringValue(rawValue) {
                values[path] = string
            }
        }
        guard let key = values[provider + ["oauth", "key"]] else { return nil }
        let storageName: String
        if key == "kimi-code" || key == "oauth/kimi-code" {
            storageName = "kimi-code"
        } else if key.hasPrefix("oauth/"), key.count > 6 {
            storageName = String(key.dropFirst(6))
        } else {
            return nil
        }
        return ManagedSignIn(
            storageName: storageName,
            oauthHost: values[provider + ["oauth", "oauth_host"]],
            baseURL: values[provider + ["base_url"]])
    }

    /// A dotted key, each part bare or quoted: `providers."managed:kimi-code".oauth`.
    static func keyPath(_ text: String) -> [String]? {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        var quoted = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
                continue
            }
            switch character {
            case "\"", "'":
                quote = character
                quoted = true
            case ".":
                parts.append(current)
                current = ""
                quoted = false
            case " ", "\t":
                continue
            default:
                current.append(character)
            }
        }
        guard quote == nil else { return nil }
        if !current.isEmpty || quoted { parts.append(current) }
        return parts.isEmpty || parts.contains(where: \.isEmpty) ? nil : parts
    }

    /// `{ storage = "file", key = "oauth/kimi-code" }` → its pairs.
    static func inlineTable(_ text: String) -> [([String], String)] {
        var body = text.trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("{"), body.hasSuffix("}") else { return [] }
        body = String(body.dropFirst().dropLast())
        var pairs: [([String], String)] = []
        for item in splitUnquoted(body, on: ",") {
            guard let equals = firstUnquoted("=", in: item), let key = keyPath(String(item[..<equals])) else { continue }
            pairs.append((key, String(item[item.index(after: equals)...]).trimmingCharacters(in: .whitespaces)))
        }
        return pairs
    }

    /// A basic `"…"` or literal `'…'` string; anything else is not one.
    static func stringValue(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            return String(value.dropFirst().dropLast())
        }
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) as? String
    }

    static func stripComment(_ line: String) -> String {
        guard let hash = firstUnquoted("#", in: line) else { return line }
        return String(line[..<hash])
    }

    static func firstUnquoted(_ target: Character, in text: String) -> String.Index? {
        var quote: Character?
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if let open = quote {
                if escaped { escaped = false } else if character == "\\", open == "\"" { escaped = true } else if character == open { quote = nil }
                continue
            }
            if character == "\"" || character == "'" { quote = character; continue }
            if character == target { return index }
        }
        return nil
    }

    static func splitUnquoted(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var rest = text
        while let index = firstUnquoted(separator, in: rest) {
            parts.append(String(rest[..<index]))
            rest = String(rest[rest.index(after: index)...])
        }
        parts.append(rest)
        return parts
    }
}

// MARK: - Device identity

/// The headers Kimi Code's sign-in server expects on a renewal
/// (`createKimiDefaultHeaders`), with QuotaBar named as the product in the
/// User-Agent and version rather than passing for Kimi Code.
enum KimiCodeIdentity {
    /// `~/.kimi-code/device_id`, which Kimi Code creates on first launch.
    /// QuotaBar never creates it: without one, it does not renew.
    static func deviceID(codeHome: URL) -> String? {
        guard let text = try? String(contentsOf: codeHome.appendingPathComponent("device_id"), encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return asciiHeader(version ?? "", fallback: "dev")
    }

    static func headers(deviceID: String, appVersion: String) -> [String: String] {
        var release = utsname()
        uname(&release)
        let kernel = withUnsafeBytes(of: &release.release) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        var name = [CChar](repeating: 0, count: 256)
        let host = gethostname(&name, name.count) == 0 ? String(cString: name) : ""
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let product = "\(os.majorVersion).\(os.minorVersion)" + (os.patchVersion != 0 ? ".\(os.patchVersion)" : "")
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x64"
        #endif
        return [
            "User-Agent": "QuotaBar/\(appVersion)",
            "X-Msh-Platform": "kimi_code_cli",
            "X-Msh-Version": appVersion,
            "X-Msh-Device-Name": asciiHeader(host),
            "X-Msh-Device-Model": asciiHeader("macOS \(product) \(arch)"),
            "X-Msh-Os-Version": asciiHeader(kernel),
            "X-Msh-Device-Id": asciiHeader(deviceID),
        ]
    }

    /// Printable ASCII only, trimmed, else the fallback — Kimi Code's `asciiHeader`.
    static func asciiHeader(_ value: String, fallback: String = "unknown") -> String {
        let cleaned = String(value.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }.map(Character.init))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? fallback : cleaned
    }
}

// MARK: - What was pasted

/// A credential pasted into Settings for Kimi Code, told apart by its shape.
public enum KimiPastedCredential: Equatable, Sendable {
    /// The kimi-auth cookie: its value, a JWT.
    case cookie(String)
    /// A Cookie header with no kimi-auth in it: nothing to send.
    case cookieWithoutToken
    /// A single word that is no cookie: a Kimi Code API key.
    case apiKey(String)
    /// Text around a key or token that cannot be told apart — spaces,
    /// colons or semicolons in it: nothing is sent.
    case unrecognized

    /// - `Authorization:` and `Bearer` in front (copied from a request) are
    ///   dropped first.
    /// - `kimi-auth` followed by `=`, `:` or a space or tab (a Cookie header,
    ///   a curl line, a DevTools row) → its value, quotes taken off.
    /// - Any other Cookie header → nothing usable.
    /// - A bare JWT (three base64url parts, the first a JSON header with
    ///   `alg`) → a kimi-auth value.
    /// - One unbroken word → an API key; anything else is unrecognized.
    public static func classify(_ raw: String) -> KimiPastedCredential {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: #"^authorization\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"^bearer\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = text.range(of: #"(?<![\w-])kimi-auth(\s*[=:]\s*|\s+)"#, options: [.regularExpression, .caseInsensitive]) {
            var rest = text[range.upperBound...]
            if let quote = rest.first, quote == "\"" || quote == "'" { rest = rest.dropFirst() }
            let value = rest.prefix { !";, \t\r\n'\"".contains($0) }
            return value.isEmpty ? .cookieWithoutToken : .cookie(String(value))
        }
        if text.lowercased().hasPrefix("cookie:")
            || text.range(of: #"^[^\s=;]+=[^;]*(;\s*[^\s=;]+=[^;]*)+;?$"#, options: .regularExpression) != nil
        {
            return .cookieWithoutToken
        }
        if isJWT(text) { return .cookie(text) }
        guard !text.isEmpty, text.rangeOfCharacter(from: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ":;"))) == nil else {
            return .unrecognized
        }
        return .apiKey(text)
    }

    static func isJWT(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_=")
        guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return false }
        var header = String(parts[0]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while header.count % 4 != 0 { header.append("=") }
        guard let data = Data(base64Encoded: header),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return object["alg"] != nil
    }

    /// A short, one-way name for a secret, for remembering things about it
    /// in memory without keeping the secret itself.
    static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}
