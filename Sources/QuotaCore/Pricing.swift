import Foundation

/// Per-million-token rates for one model.
public struct ModelRates: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheWrite: Double
    public var cacheRead: Double
    /// 1-hour cache writes cost 2x input on Anthropic models; the catalog only
    /// publishes the 5-minute figure, so the long one is derived.
    public var cacheWriteLong: Double { input * 2 }

    public init(input: Double, output: Double, cacheWrite: Double, cacheRead: Double) {
        self.input = input
        self.output = output
        self.cacheWrite = cacheWrite
        self.cacheRead = cacheRead
    }
}

/// Model prices fetched from a maintained catalog, cached on disk.
///
/// A hardcoded table is wrong sooner than it looks: this account's Codex usage
/// is `gpt-5.6-sol`, which the built-in table never knew and priced through a
/// `gpt-5` prefix at $1.25/$10 against a real $4/$20 — understating that
/// provider roughly threefold. The built-in table stays as the offline
/// fallback, not as the source of truth.
public final class PricingCatalog: @unchecked Sendable {
    public static let shared = PricingCatalog()

    /// LiteLLM's catalog: a single JSON keyed by model id, widely used for
    /// exactly this and updated as providers change prices.
    private static let source = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    /// Refetched at most this often; prices move in weeks, not minutes.
    private static let maxAge: TimeInterval = 24 * 3600

    private let lock = NSLock()
    private var rates: [String: ModelRates] = [:]
    private var resolved: [String: ModelRates?] = [:]
    private let cacheURL: URL

    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/quotabar/pricing.json")
        loadCache()
    }

    /// Exact model id first, then the id with a trailing date stamp removed.
    /// No prefix matching here — that is what got the built-in table wrong.
    public func rates(for model: String) -> ModelRates? {
        let key = model.lowercased()
        lock.lock()
        if let memo = resolved[key] {
            lock.unlock()
            return memo
        }
        let table = rates
        lock.unlock()

        var match = table[key]
        if match == nil {
            // "claude-opus-4-5-20251101" -> "claude-opus-4-5"
            let trimmed = key.replacingOccurrences(
                of: "-\\d{8}$", with: "", options: .regularExpression)
            match = table[trimmed]
        }
        lock.lock()
        resolved[key] = match
        lock.unlock()
        return match
    }

    public var isLoaded: Bool {
        lock.lock(); defer { lock.unlock() }
        return !rates.isEmpty
    }

    public var modelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return rates.count
    }

    /// Fetches the catalog when the cache is missing or stale. Never throws:
    /// pricing is an enhancement, and the built-in table covers a failure.
    public func refreshIfNeeded() async {
        if let age = cacheAge(), age < Self.maxAge, isLoaded { return }
        guard let response = try? await HTTP.get(Self.source),
              response.status == 200,
              let parsed = Self.parse(response.data),
              !parsed.isEmpty
        else { return }

        install(parsed)
        writeCache(parsed)
    }

    /// Kept synchronous so the lock is never held across an await.
    private func install(_ table: [String: ModelRates]) {
        lock.lock()
        rates = table
        resolved.removeAll()
        lock.unlock()
    }

    /// Extracts just the four rates we price with. The published catalog is
    /// ~1.9MB of mostly context-window metadata; the trimmed cache is a
    /// fraction of that.
    static func parse(_ data: Data) -> [String: ModelRates]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var out: [String: ModelRates] = [:]
        for (model, value) in root {
            guard let entry = value as? [String: Any],
                  let input = entry["input_cost_per_token"] as? Double,
                  let output = entry["output_cost_per_token"] as? Double,
                  input > 0 || output > 0
            else { continue }
            let million = 1_000_000.0
            out[model.lowercased()] = ModelRates(
                input: input * million,
                output: output * million,
                cacheWrite: (entry["cache_creation_input_token_cost"] as? Double ?? 0) * million,
                cacheRead: (entry["cache_read_input_token_cost"] as? Double ?? 0) * million)
        }
        return out
    }

    // MARK: Cache

    private func cacheAge() -> TimeInterval? {
        guard let modified = try? FileManager.default
            .attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let decoded = try? JSONDecoder().decode([String: ModelRates].self, from: data)
        else { return }
        lock.lock()
        rates = decoded
        lock.unlock()
    }

    private func writeCache(_ table: [String: ModelRates]) {
        do {
            try FileManager.default.createDirectory(
                at: cacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(table).write(to: cacheURL, options: [.atomic])
        } catch {
            // Cache is best-effort; the in-memory table is already updated.
        }
    }
}
