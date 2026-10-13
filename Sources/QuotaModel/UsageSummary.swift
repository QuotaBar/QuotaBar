import Foundation

/// A view of the already merged CLI readings. Balance deductions are a
/// separate source and are never added to these estimates a second time.
public struct UsageSummary {
    public enum Period: String, CaseIterable, Identifiable {
        case today, yesterday, window
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .today: L10n.t("Today", "今日")
            case .yesterday: L10n.t("Yesterday", "昨日")
            case .window: L10n.t("30 days", "30 天")
            }
        }
    }

    public struct Provider: Identifiable {
        public var id: ProviderID
        public var usd: Double
        public var tokens: Int
        public var models: [CloudSpend.Model]
        public var estimated: Bool
    }

    public struct Day: Identifiable {
        public var date: Date
        public var providers: [Provider]
        public var id: Date { date }
        public var usd: Double { providers.reduce(0) { $0 + $1.usd } }
        public var tokens: Int { providers.reduce(0) { $0 + $1.tokens } }
    }

    public let readings: MergedReadings
    public init(readings: MergedReadings) { self.readings = readings }

    public func providers(in period: Period) -> [Provider] {
        readings.items.compactMap { item in
            guard let spend = item.spend,
                  period != .window || spend.windowDays == 30,
                  let value = spend.period(period.rawValue) else { return nil }
            return Provider(id: item.provider, usd: value.usd, tokens: value.tokens,
                            models: value.models, estimated: spend.estimated)
        }.sorted { $0.usd == $1.usd ? $0.tokens > $1.tokens : $0.usd > $1.usd }
    }

    /// Keep only reported dates. A missing reading is not a zero-use day.
    /// Day rows have no model split: the wire format only has period models.
    public func days(calendar: Calendar = .current) -> [Day] {
        var values: [Date: [ProviderID: Provider]] = [:]
        for item in readings.items {
            guard let spend = item.spend else { continue }
            for day in spend.trend {
                let date = calendar.startOfDay(for: day.day)
                var value = values[date]?[item.provider] ?? Provider(
                    id: item.provider, usd: 0, tokens: 0, models: [], estimated: spend.estimated)
                value.usd += day.usd
                value.tokens += day.tokens
                values[date, default: [:]][item.provider] = value
            }
        }
        guard let latest = values.keys.max(),
              let start = calendar.date(byAdding: .day, value: -29, to: latest) else { return [] }
        return values.keys.filter { $0 >= start }.sorted().map { date in
            Day(date: date, providers: (values[date] ?? [:]).values.sorted { $0.id.rawValue < $1.id.rawValue })
        }
    }
}
