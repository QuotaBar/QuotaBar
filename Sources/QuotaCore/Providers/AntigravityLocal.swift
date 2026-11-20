import Foundation

// MARK: - Antigravity's own language server

/// The quota Antigravity itself shows, asked of the language server the app
/// runs on the loopback interface (issue #4).
///
/// The sign-in token Antigravity leaves in the keychain and in
/// `~/.gemini/jetski-standalone-oauth-token` is written when you sign in and
/// not again: an hour later it has expired however long the app stays open,
/// and refreshing it would take Antigravity's own OAuth client, which is not
/// QuotaBar's to carry. The language server needs no token of ours, and it
/// answers with the limits as the app groups them — Gemini, and Claude and
/// GPT, each with a 5-hour and a weekly limit. The cloud route asks Google
/// for the same summary, with a token that lasts an hour.
///
/// It is found by its command line: the `language_server` inside
/// `Antigravity.app`, with the `--csrf_token` it checks on every call. Its
/// ports are whatever was free at launch, so `lsof` names them; one speaks
/// HTTPS with a certificate of its own, one plain HTTP, and both answer the
/// same. The IDE ships the same binary but answers the quota summary with
/// 404, so only the app's servers are asked. Measured against Antigravity
/// 2.14.0, 2026-09-16.
///
/// Since late 2026 Google ships it inside `Gemini.app` (issue #11): an
/// `agy --hub` helper with no `--csrf_token` on its command line, which
/// writes its ports and token to `~/.gemini/antigravity/daemon/hub_<port>.json`
/// at every launch instead. Same service, same answers.
enum AntigravityLocal {
    struct Server: Equatable {
        let pid: Int32
        let csrfToken: String
    }

    enum Reading {
        case quota(UsageSnapshot)
        /// Neither the app nor its language server is running.
        case notRunning
        /// Antigravity is running, but no server gave a quota.
        case noAnswer
    }

    static let service = "exa.language_server_pb.LanguageServerService"

    static var appPaths: [String] {
        ["/Applications/Antigravity.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Antigravity.app").path]
    }

    /// Where Antigravity lives now: inside the Gemini app. Its version is
    /// Gemini's, not Antigravity's, so `installedVersion` does not read it.
    static var geminiAppPaths: [String] {
        ["/Applications/Gemini.app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Gemini.app").path]
    }

    /// The app is on this Mac, signed in or not.
    static var isInstalled: Bool {
        (appPaths + geminiAppPaths).contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// The hubs' own records of themselves.
    static var daemonDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
    }

    /// The installed app's version, `2.28.0`.
    static var installedVersion: String? {
        appPaths.lazy.compactMap { path -> String? in
            let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
            guard let info = NSDictionary(contentsOf: plist) else { return nil }
            guard let version = info["CFBundleShortVersionString"] as? String, !version.isEmpty else { return nil }
            return version
        }.first
    }

    static func read() async -> Reading {
        // Gemini.app's hub says where it is; no process list needed.
        let hubs = hubs(in: daemonDirectory)
        for hub in hubs {
            for (scheme, port) in hub.endpoints {
                if let snapshot = await quota(scheme: scheme, port: port, server: hub.server) { return .quota(snapshot) }
            }
        }
        let list = await Task.detached { ToolRunner.run("/bin/ps", ["-ax", "-o", "pid=,command="], timeout: 5) }.value
        let text = list.map { String(decoding: $0.output, as: UTF8.self) } ?? ""
        let servers = servers(inProcessList: text)
        guard !servers.isEmpty || !hubs.isEmpty || isAppRunning(inProcessList: text) else { return .notRunning }
        for server in servers {
            let lsof = await Task.detached {
                ToolRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(server.pid)], timeout: 5)
            }.value
            for port in ports(inListing: lsof.map { String(decoding: $0.output, as: UTF8.self) } ?? "") {
                for scheme in ["https", "http"] {
                    if let snapshot = await quota(scheme: scheme, port: port, server: server) { return .quota(snapshot) }
                }
            }
        }
        return .noAnswer
    }

    /// The quota one server gives, with the plan and address when it says.
    private static func quota(scheme: String, port: Int, server: Server) async -> UsageSnapshot? {
        guard let summary = await call("RetrieveUserQuotaSummary", scheme: scheme, port: port, server: server),
              var snapshot = try? parseSummary(summary)
        else { return nil }
        if let status = await call("GetUserStatus", scheme: scheme, port: port, server: server) {
            (snapshot.planName, snapshot.account) = userStatus(status)
        }
        return snapshot
    }

    // MARK: Gemini.app's hub

    struct Hub: Equatable {
        let server: Server
        let httpsPort: Int?
        let httpPort: Int?

        /// HTTPS first, as the language server is asked.
        var endpoints: [(scheme: String, port: Int)] {
            [httpsPort.map { ("https", $0) }, httpPort.map { ("http", $0) }].compactMap { $0 }
        }
    }

    /// The running hubs `hub_*.json` names, newest first. A file whose
    /// process is gone is left alone: the app removes its last one when it
    /// starts again, but not when it quits.
    static func hubs(in directory: URL, isAlive: (Int32) -> Bool = processIsAlive) -> [Hub] {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .map { url in (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        return files.compactMap { url, _ -> Hub? in
            guard let data = try? Data(contentsOf: url), let hub = hub(data), isAlive(hub.server.pid) else { return nil }
            return hub
        }
    }

    /// `{"pid": 3884, "httpsPort": 50003, "httpPort": 50000, "lsVersion": "2.31.0", "csrfToken": "…"}`
    static func hub(_ data: Data) -> Hub? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pid = (object["pid"] as? NSNumber)?.int32Value, pid > 0,
              let token = object["csrfToken"] as? String, !token.isEmpty
        else { return nil }
        let https = (object["httpsPort"] as? NSNumber)?.intValue
        let http = (object["httpPort"] as? NSNumber)?.intValue
        guard https != nil || http != nil else { return nil }
        return Hub(server: Server(pid: pid, csrfToken: token), httpsPort: https, httpPort: http)
    }

    static func processIsAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    // MARK: Finding it

    /// The app's language servers in `ps -ax -o pid=,command=` output.
    static func servers(inProcessList text: String) -> [Server] {
        text.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.contains("/Antigravity.app/"), line.contains("/language_server"),
                  let space = line.firstIndex(of: " "), let pid = Int32(line[..<space]),
                  let token = flag("--csrf_token", in: line), !token.isEmpty
            else { return nil }
            return Server(pid: pid, csrfToken: token)
        }
    }

    /// The app itself, so a server that is still starting is told apart
    /// from an app that is not open.
    static func isAppRunning(inProcessList text: String) -> Bool {
        text.contains("/Antigravity.app/Contents/MacOS/Antigravity") || text.contains("/Gemini.app/Contents/MacOS/Gemini")
    }

    static func flag(_ name: String, in line: String) -> String? {
        let parts = line.split(separator: " ")
        for (index, part) in parts.enumerated() {
            if part == name, index + 1 < parts.count { return String(parts[index + 1]) }
            if part.hasPrefix(name + "=") { return String(part.dropFirst(name.count + 1)) }
        }
        return nil
    }

    /// Listening loopback ports in `lsof -nP -iTCP -sTCP:LISTEN` output.
    static func ports(inListing text: String) -> [Int] {
        text.split(separator: "\n").compactMap { line in
            guard line.contains("(LISTEN)"),
                  line.contains("127.0.0.1:") || line.contains("[::1]:") || line.contains("localhost:"),
                  let match = line.range(of: #":(\d+) \(LISTEN\)"#, options: .regularExpression)
            else { return nil }
            return Int(line[match].dropFirst().prefix { $0.isNumber })
        }
    }

    // MARK: Asking it

    static func call(_ method: String, scheme: String, port: Int, server: Server) async -> Data? {
        guard let url = URL(string: "\(scheme)://127.0.0.1:\(port)/\(service)/\(method)") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 4)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(server.csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        request.httpBody = Data(#"{"metadata":{"ideName":"antigravity","extensionName":"antigravity","ideVersion":"unknown","locale":"en"}}"#.utf8)
        guard let (data, response) = try? await Loopback.shared.session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }

    /// Its own session: no proxy — the owner's proxy has no business with
    /// loopback — and the server's self-signed certificate accepted for
    /// 127.0.0.1 and nothing else.
    final class Loopback: NSObject, URLSessionDelegate, @unchecked Sendable {
        static let shared = Loopback()

        lazy var session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = [:]
            configuration.timeoutIntervalForRequest = 4
            configuration.urlCache = nil
            configuration.httpCookieStorage = nil
            return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }()

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
        {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  space.host == "127.0.0.1", let trust = space.serverTrust
            else { return completionHandler(.performDefaultHandling, nil) }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    // MARK: Reading the answer

    struct Summary: Decodable {
        struct Response: Decodable { let groups: [Group]? }
        struct Group: Decodable {
            let displayName: String?
            let buckets: [Bucket]?
        }
        struct Bucket: Decodable {
            let bucketId: String?
            let window: String?
            let remainingFraction: Double?
            let resetTime: String?
            let disabled: Bool?
        }
        /// The language server wraps Google's answer in `response`.
        let response: Response?
        /// Google's own answer, as the cloud route gets it.
        let groups: [Group]?
    }

    /// `{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h",
    /// "window":"5h","remainingFraction":1,"resetTime":"2026-09-16T14:42:11Z"}, …]}, …]}}`
    /// from the language server, which passes on Google's
    /// `retrieveUserQuotaSummary` as it is; the cloud route reads the same
    /// answer without the `response` around it.
    ///
    /// One window per bucket, scoped to its group. The answer is protobuf's
    /// JSON, which leaves out a field at its zero value: a bucket with no
    /// `remainingFraction` has none left, not an unknown amount. A bucket
    /// whose window cannot be read, or that is marked disabled, is left out
    /// rather than guessed at.
    static func parseSummary(_ data: Data, plan: String? = nil, account: String? = nil) throws -> UsageSnapshot {
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { throw ProviderError.badResponse }
        var windows: [UsageWindow] = []
        for group in summary.response?.groups ?? summary.groups ?? [] {
            let scope = groupName(group.displayName)
            let buckets = (group.buckets ?? []).compactMap { bucket -> (Int, Summary.Bucket)? in
                guard bucket.disabled != true else { return nil }
                return windowSeconds(bucket.window ?? bucket.bucketId).map { ($0, bucket) }
            }
            for (seconds, bucket) in buckets.sorted(by: { $0.0 < $1.0 }) {
                let remaining = min(max(bucket.remainingFraction ?? 0, 0), 1)
                windows.append(UsageWindow(
                    title: "\(WindowTitle.forSeconds(seconds)) · \(scope)",
                    usedPercent: (1 - remaining) * 100,
                    resetsAt: LocalCredentials.parseFlexibleISO(bucket.resetTime),
                    windowSeconds: seconds,
                    scope: scope))
            }
        }
        guard !windows.isEmpty else { throw ProviderError.badResponse }
        return UsageSnapshot(planName: plan, account: account, windows: windows)
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude and GPT".
    static func groupName(_ raw: String?) -> String {
        let name = (raw ?? "").trimmingCharacters(in: .whitespaces)
        let trimmed = name.replacingOccurrences(of: #"\s+models$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return trimmed.isEmpty ? "Antigravity" : trimmed
    }

    /// `5h`, `weekly`, `daily`, or a bucket id ending in one of them.
    static func windowSeconds(_ raw: String?) -> Int? {
        guard let value = raw?.lowercased() else { return nil }
        if value.hasSuffix("weekly") || value.hasSuffix("week") { return 604_800 }
        if value.hasSuffix("daily") || value.hasSuffix("day") { return 86_400 }
        if value.hasSuffix("monthly") { return 2_592_000 }
        if let match = value.range(of: #"(\d+)h$"#, options: .regularExpression),
           let hours = Int(value[match].dropLast())
        {
            return hours * 3600
        }
        return nil
    }

    /// `GetUserStatus`: the plan as the app names it and the signed-in address.
    static func userStatus(_ data: Data) -> (plan: String?, account: String?) {
        guard let root = ProviderJSON.object(data) as? [String: Any],
              let status = root["userStatus"] as? [String: Any]
        else { return (nil, nil) }
        let plan = ((status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any])?["planName"] as? String
        let email = status["email"] as? String
        return (plan.flatMap { $0.isEmpty ? nil : $0 }, email.flatMap { $0.isEmpty ? nil : $0 })
    }
}
