import Foundation

// MARK: - What the phone's detail page shows beyond the windows

/// A provider's spend as the Mac's card shows it under its arrow: today,
/// yesterday and the rolling window, each with the models it went on, and a
/// month of days for the trend. Worked out on the Mac from the CLIs' own
/// session logs, so only the providers with a CLI behind them have it.
///
/// Dollars throughout; `CloudReadings.currency` and `usdRate` say how the
/// Mac shows them, so the phone shows the same figure.
public struct CloudSpend: Sendable, Equatable {
    public struct Period: Sendable, Equatable, Identifiable {
        /// "today", "yesterday" or "window".
        public var id: String
        public var usd: Double
        public var tokens: Int
        /// Most spent first, the busiest few only.
        public var models: [Model]

        public init(id: String, usd: Double, tokens: Int, models: [Model] = []) {
            self.id = id
            self.usd = usd
            self.tokens = tokens
            self.models = models
        }

        public var isEmpty: Bool { usd <= 0 && tokens <= 0 }
    }

    public struct Model: Sendable, Equatable, Identifiable, Codable {
        public var name: String
        public var usd: Double
        public var tokens: Int

        public init(name: String, usd: Double, tokens: Int) {
            self.name = name
            self.usd = usd
            self.tokens = tokens
        }

        public var id: String { name }
    }

    public struct Day: Sendable, Equatable, Identifiable, Codable {
        public var day: Date
        public var usd: Double
        public var tokens: Int

        public init(day: Date, usd: Double, tokens: Int) {
            self.day = day
            self.usd = usd
            self.tokens = tokens
        }

        public var id: Date { day }
    }

    public var periods: [Period]
    /// How many days "window" covers.
    public var windowDays: Int
    /// Oldest first, one entry per day, empty days included.
    public var trend: [Day]
    /// Priced from token counts at list rates, not a bill: a plan's included
    /// usage costs nothing, and the figure says what it would have cost.
    public var estimated: Bool

    public init(periods: [Period], windowDays: Int, trend: [Day], estimated: Bool) {
        self.periods = periods
        self.windowDays = windowDays
        self.trend = trend
        self.estimated = estimated
    }

    public var isEmpty: Bool { periods.allSatisfy(\.isEmpty) && trend.allSatisfy { $0.tokens == 0 } }

    public func period(_ id: String) -> Period? { periods.first { $0.id == id } }

    /// "Today", "Yesterday", "30 days".
    public func title(of period: Period) -> String {
        switch period.id {
        case "today": L10n.t("Today", "今日")
        case "yesterday": L10n.t("Yesterday", "昨日")
        default: L10n.t("\(windowDays) days", "\(windowDays) 天")
        }
    }
}

extension CloudSpend.Period: Codable {
    private enum CodingKeys: String, CodingKey { case id, usd, tokens, models }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        usd = (try? c.decodeIfPresent(Double.self, forKey: .usd)) ?? 0
        tokens = (try? c.decodeIfPresent(Int.self, forKey: .tokens)) ?? 0
        models = (try? c.decodeIfPresent([CloudSpend.Model].self, forKey: .models)) ?? []
    }
}

extension CloudSpend: Codable {
    private enum CodingKeys: String, CodingKey { case periods, windowDays, trend, estimated }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        periods = (try? c.decodeIfPresent([Period].self, forKey: .periods)) ?? []
        windowDays = (try? c.decodeIfPresent(Int.self, forKey: .windowDays)) ?? 30
        trend = (try? c.decodeIfPresent([Day].self, forKey: .trend)) ?? []
        estimated = (try? c.decodeIfPresent(Bool.self, forKey: .estimated)) ?? true
    }
}

/// Where the Mac's card links to: the provider's console for the account in
/// use. The status page is not a link on the phone — it reads the page
/// itself and shows what it says.
public struct CloudLinks: Sendable, Equatable, Codable {
    public var console: URL?

    public init(console: URL? = nil) {
        self.console = console
    }

    public var isEmpty: Bool { console == nil }
}

// MARK: - Money as the Mac shows it

/// The Mac's currency choice, carried with the readings: a spend in dollars
/// becomes the figure the Mac's own card shows.
public struct CloudMoney: Sendable, Equatable {
    public var currency: String
    /// Units of `currency` per dollar; nil keeps dollars.
    public var usdRate: Double?

    public init(currency: String = "USD", usdRate: Double? = nil) {
        self.currency = currency
        self.usdRate = usdRate
    }

    /// "$4,557.33", "¥32,473.21".
    public func format(_ usd: Double) -> String {
        guard currency != "USD", let usdRate else { return QuotaFormat.amount(usd, code: "USD") }
        return QuotaFormat.amount(usd * usdRate, code: currency)
    }
}
