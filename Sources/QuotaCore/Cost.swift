import Foundation

// MARK: - Local cost estimation (no network, reads the CLIs' own session logs)

/// Where a locally-logged token event came from.
public enum CostSource: String, Sendable, CaseIterable, Codable {
    case claudeCode
    case codexCLI

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        }
    }
}

public struct CostSummary: Sendable, Equatable {
    public var todayUSD: Double = 0
    public var monthUSD: Double = 0
    public var todayTokens: Int = 0
    public var monthTokens: Int = 0
    /// Month-to-date spend split by CLI, so the panel can attribute the total.
    public var monthBySource: [CostSource: Double] = [:]
    /// Billable events that were dropped as duplicates — the same assistant
    /// turn is written to several session files when a conversation is
    /// resumed or branched into a sidechain.
    public var deduplicated: Int = 0

    public static let empty = CostSummary()

    public init(
        todayUSD: Double = 0,
        monthUSD: Double = 0,
        todayTokens: Int = 0,
        monthTokens: Int = 0,
        monthBySource: [CostSource: Double] = [:],
        deduplicated: Int = 0)
    {
        self.todayUSD = todayUSD
        self.monthUSD = monthUSD
        self.todayTokens = todayTokens
        self.monthTokens = monthTokens
        self.monthBySource = monthBySource
        self.deduplicated = deduplicated
    }

    public var hasData: Bool { monthUSD > 0 || monthTokens > 0 }
}

private struct TokenEvent {
    let timestamp: Date
    let source: CostSource
    let model: String
    /// Fresh (uncached) input only.
    let input: Int
    let output: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    let cacheRead: Int
    /// Stable identity of the billable API call; nil when the log gives us
    /// nothing to key on and the event has to be trusted as unique.
    let dedupeKey: String?
}

/// USD per million tokens; `marker` is substring-matched against the logged
/// model id, most specific first.
private struct Rates {
    let input: Double
    let output: Double
    /// 5-minute ephemeral cache write (1.25x input on Anthropic models).
    let cacheWrite5m: Double
    /// 1-hour ephemeral cache write (2x input on Anthropic models).
    let cacheWrite1h: Double
    let cacheRead: Double
}

/// Anthropic list prices; OpenAI models charge nothing to write a cache entry.
/// Order matters — "sonnet-5" must be tested before the generic "sonnet".
private let pricingTable: [(marker: String, rates: Rates)] = [
    ("fable", Rates(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1.0)),
    ("mythos", Rates(input: 10, output: 50, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1.0)),
    ("opus", Rates(input: 5, output: 25, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50)),
    ("sonnet-5", Rates(input: 2, output: 10, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.20)),
    ("sonnet", Rates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)),
    ("haiku", Rates(input: 1, output: 5, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10)),
    ("gpt-5", Rates(input: 1.25, output: 10, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.125)),
    ("codex", Rates(input: 1.25, output: 10, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.125)),
    ("o3", Rates(input: 2, output: 8, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.5)),
    ("o4", Rates(input: 1.1, output: 4.4, cacheWrite5m: 0, cacheWrite1h: 0, cacheRead: 0.275)),
]

/// Exposed for the test suite so the price table stays pinned to real numbers.
public enum Pricing {
    /// (input, output, cacheWrite5m, cacheWrite1h, cacheRead) USD per million tokens.
    public static func perMillion(for model: String) -> (Double, Double, Double, Double, Double) {
        let r = rates(for: model)
        return (r.input, r.output, r.cacheWrite5m, r.cacheWrite1h, r.cacheRead)
    }
}

private func rates(for model: String) -> Rates {
    let lowered = model.lowercased()
    for entry in pricingTable where lowered.contains(entry.marker) {
        return entry.rates
    }
    // Unknown model: price it as mid-tier Sonnet rather than as free.
    return Rates(input: 3, output: 15, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30)
}

private func cost(of event: TokenEvent) -> Double {
    let r = rates(for: event.model)
    return (Double(event.input) * r.input
        + Double(event.output) * r.output
        + Double(event.cacheWrite5m) * r.cacheWrite5m
        + Double(event.cacheWrite1h) * r.cacheWrite1h
        + Double(event.cacheRead) * r.cacheRead) / 1_000_000
}

private func tokens(of event: TokenEvent) -> Int {
    event.input + event.output + event.cacheWrite5m + event.cacheWrite1h + event.cacheRead
}

/// Where the CLIs keep their session logs. Injectable so the estimator can be
/// tested against fixtures instead of the developer's real history.
public struct CostPaths: Sendable {
    public var claudeProjects: URL
    public var codexSessions: URL

    public init(claudeProjects: URL, codexSessions: URL) {
        self.claudeProjects = claudeProjects
        self.codexSessions = codexSessions
    }

    public static var `default`: CostPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CostPaths(
            claudeProjects: home.appendingPathComponent(".claude/projects"),
            codexSessions: home.appendingPathComponent(".codex/sessions"))
    }
}

public enum CostEstimator {
    /// In-memory memo keyed by (path, mtime, size) so steady-state refreshes
    /// only re-parse files that actually changed.
    private static var cache: [String: [TokenEvent]] = [:]
    private static let lock = NSLock()
    /// Lines bigger than this are base64/tool-output blobs — never usage rows.
    private static let maxLineBytes = 200_000

    public static func summary(
        paths: CostPaths = .default,
        lookbackDays: Int = 31,
        now: Date = Date()) -> CostSummary
    {
        let cutoff = now.addingTimeInterval(-Double(lookbackDays) * 86400)
        var events = scanClaude(root: paths.claudeProjects, cutoff: cutoff)
        events.append(contentsOf: scanCodex(root: paths.codexSessions, cutoff: cutoff))

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? dayStart

        // The same assistant turn is logged into every session file that
        // replays it (resume, sidechain, branch). Without this the month total
        // roughly doubles.
        var seen = Set<String>()
        var summary = CostSummary()
        for event in events {
            if let key = event.dedupeKey {
                guard seen.insert(key).inserted else {
                    summary.deduplicated += 1
                    continue
                }
            }
            guard event.timestamp >= monthStart else { continue }
            let cost = cost(of: event)
            let count = tokens(of: event)
            summary.monthUSD += cost
            summary.monthTokens += count
            summary.monthBySource[event.source, default: 0] += cost
            if event.timestamp >= dayStart {
                summary.todayUSD += cost
                summary.todayTokens += count
            }
        }
        return summary
    }

    /// Drops the parsed-file memo; used by tests and after a manual rescan.
    public static func resetCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }

    // MARK: Claude Code (~/.claude/projects/**/*.jsonl)

    private static func scanClaude(root: URL, cutoff: Date) -> [TokenEvent] {
        return walk(root, cutoff: cutoff, filter: { $0.pathExtension == "jsonl" }) { url, formatter in
            var out: [TokenEvent] = []
            streamLines(url) { line in
                guard line.contains("\"assistant\""), line.contains("\"usage\"") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      obj["type"] as? String == "assistant",
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { return }

                // Anthropic bills 5-minute and 1-hour cache writes at different
                // multiples of the input rate; fall back to the flat total when
                // the breakdown is absent (older log format).
                let totalWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
                let breakdown = usage["cache_creation"] as? [String: Any]
                let write1h = breakdown?["ephemeral_1h_input_tokens"] as? Int ?? 0
                let write5m = breakdown.map { $0["ephemeral_5m_input_tokens"] as? Int ?? 0 }
                    ?? totalWrite

                let messageID = message["id"] as? String
                let requestID = obj["requestId"] as? String
                let dedupeKey = (messageID ?? requestID).map { _ in
                    "claude|\(messageID ?? "")|\(requestID ?? "")"
                }

                out.append(TokenEvent(
                    timestamp: parseTimestamp(obj["timestamp"], formatter),
                    source: .claudeCode,
                    model: message["model"] as? String ?? "claude-sonnet",
                    input: usage["input_tokens"] as? Int ?? 0,
                    output: usage["output_tokens"] as? Int ?? 0,
                    cacheWrite5m: write5m,
                    cacheWrite1h: write1h,
                    cacheRead: usage["cache_read_input_tokens"] as? Int ?? 0,
                    dedupeKey: dedupeKey))
            }
            return out
        }
    }

    // MARK: Codex CLI (~/.codex/sessions/**/rollout-*.jsonl)

    private static func scanCodex(root: URL, cutoff: Date) -> [TokenEvent] {
        return walk(root, cutoff: cutoff, filter: { $0.lastPathComponent.hasPrefix("rollout-") }) { url, formatter in
            var out: [TokenEvent] = []
            var currentModel = "gpt-5-codex"
            streamLines(url) { line in
                guard line.contains("turn_context") || line.contains("token_count") else { return }
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                let type = obj["type"] as? String ?? ""
                let payload = obj["payload"] as? [String: Any] ?? [:]
                if type == "turn_context", let model = payload["model"] as? String {
                    currentModel = model
                    return
                }
                guard type == "event_msg", payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else { return }

                // Codex reports `input_tokens` inclusive of `cached_input_tokens`;
                // billing the full figure *and* the cached figure double-charges
                // every cache hit.
                let rawInput = last["input_tokens"] as? Int ?? 0
                let cached = last["cached_input_tokens"] as? Int ?? 0
                let timestamp = parseTimestamp(obj["timestamp"], formatter)
                let output = last["output_tokens"] as? Int ?? 0

                out.append(TokenEvent(
                    timestamp: timestamp,
                    source: .codexCLI,
                    model: currentModel,
                    input: max(0, rawInput - cached),
                    output: output,
                    cacheWrite5m: last["cache_write_input_tokens"] as? Int ?? 0,
                    cacheWrite1h: 0,
                    cacheRead: cached,
                    dedupeKey: "codex|\(obj["timestamp"] as? String ?? "")|\(rawInput)|\(output)"))
            }
            return out
        }
    }

    // MARK: Shared plumbing

    private static func walk(
        _ root: URL,
        cutoff: Date,
        filter: @escaping (URL) -> Bool,
        parse: (URL, ISO8601DateFormatter) -> [TokenEvent]) -> [TokenEvent]
    {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles])
        else { return [] }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var out: [TokenEvent] = []
        for case let url as URL in enumerator {
            guard filter(url) else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            guard let mtime = values?.contentModificationDate, mtime >= cutoff else { continue }
            // Size is part of the key: an append within the same mtime second
            // would otherwise serve a stale parse.
            let key = "\(url.path)|\(mtime.timeIntervalSince1970)|\(values?.fileSize ?? -1)"
            lock.lock()
            let cached = cache[key]
            lock.unlock()
            if let cached {
                out.append(contentsOf: cached)
            } else {
                let parsed = parse(url, formatter)
                lock.lock()
                cache[key] = parsed
                lock.unlock()
                out.append(contentsOf: parsed)
            }
        }
        return out
    }

    private static func streamLines(_ url: URL, _ handle: (String) -> Void) {
        guard let handleFile = FileHandle(forReadingAtPath: url.path) else { return }
        defer { try? handleFile.close() }
        var remainder = Data()
        // Set while discarding an oversized line so its tail isn't mistaken
        // for the start of the next one.
        var skipping = false
        let chunkSize = 1 << 20
        while true {
            let chunk = handleFile.readData(ofLength: chunkSize)
            if chunk.isEmpty { break }
            var data = remainder
            data.append(chunk)
            var start = data.startIndex
            while let newline = data[start...].firstIndex(of: 0x0A) {
                let lineData = data[start..<newline]
                if skipping {
                    skipping = false
                } else if lineData.count <= maxLineBytes,
                          let line = String(data: lineData, encoding: .utf8)
                {
                    handle(line)
                }
                start = data.index(after: newline)
            }
            remainder = Data(data[start...])
            if remainder.count > maxLineBytes {
                remainder = Data()
                skipping = true
            }
        }
        if !skipping, !remainder.isEmpty, remainder.count <= maxLineBytes,
           let line = String(data: remainder, encoding: .utf8)
        {
            handle(line)
        }
    }

    private static func parseTimestamp(_ raw: Any?, _ formatter: ISO8601DateFormatter) -> Date {
        if let string = raw as? String {
            if let date = formatter.date(from: string) { return date }
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) { return date }
        }
        return .distantPast
    }
}
