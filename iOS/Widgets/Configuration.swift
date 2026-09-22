import AppIntents
import QuotaModel
import WidgetKit

// MARK: - What a widget is set to show

/// A provider to pick in a widget's settings: every provider the Macs have
/// sent, else every one QuotaBar knows.
struct ProviderEntity: AppEntity {
    let id: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let defaultQuery = ProviderQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(ProviderID(rawValue: id)?.displayName ?? id)")
    }

    var provider: ProviderID? { ProviderID(rawValue: id) }
}

struct ProviderQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ProviderEntity] {
        identifiers.map(ProviderEntity.init(id:))
    }

    func suggestedEntities() async throws -> [ProviderEntity] {
        let synced = ReadingsCache.merged.items.map(\.provider)
        let ids = synced.isEmpty ? ProviderID.allCases : synced
        return ids.map { ProviderEntity(id: $0.rawValue) }
    }

    func defaultResult() async -> ProviderEntity? {
        ReadingsCache.merged.items.first.map { ProviderEntity(id: $0.provider.rawValue) }
    }
}

extension WindowChoice: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Limit"
    static let caseDisplayRepresentations: [WindowChoice: DisplayRepresentation] = [
        .automatic: DisplayRepresentation(title: "Automatic"),
        .short: DisplayRepresentation(title: "Short (5 hours)"),
        .long: DisplayRepresentation(title: "Long (weekly or monthly)"),
    ]
}

/// How one provider is drawn. Each works at every size; the medium and
/// large sizes build on it rather than replacing it.
enum ProviderStyle: String, AppEnum {
    /// One ring: what is left of the chosen limit.
    case ring
    /// Two rings, one inside the other: the short limit outside, the long
    /// one inside — both horizons at a glance, as the Mac's dual glyph.
    case dualRing
    /// The stepped bars of the app's cards, one per limit.
    case bars
    /// The figure alone, large.
    case number

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [ProviderStyle: DisplayRepresentation] = [
        .ring: DisplayRepresentation(title: "Ring"),
        .dualRing: DisplayRepresentation(title: "Two rings"),
        .bars: DisplayRepresentation(title: "Stepped bars"),
        .number: DisplayRepresentation(title: "Big number"),
    ]
}

/// How several providers are drawn together.
enum OverviewStyle: String, AppEnum {
    /// A ring per provider.
    case rings
    /// A row per provider with its stepped bar.
    case list
    /// A row per provider with both limits as figures, compact.
    case figures

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [OverviewStyle: DisplayRepresentation] = [
        .rings: DisplayRepresentation(title: "Rings"),
        .list: DisplayRepresentation(title: "Stepped bars"),
        .figures: DisplayRepresentation(title: "Figures"),
    ]
}

struct ProviderWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider"
    static let description = IntentDescription("One provider's limit, from QuotaBar on your Mac.")

    @Parameter(title: "Provider")
    var provider: ProviderEntity?

    @Parameter(title: "Limit", default: .automatic)
    var window: WindowChoice

    @Parameter(title: "Style", default: .ring)
    var style: ProviderStyle
}

struct OverviewWidgetIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Overview"
    static let description = IntentDescription("Every provider your Mac reads.")

    @Parameter(title: "Style", default: .rings)
    var style: OverviewStyle

    @Parameter(title: "Limit", default: .automatic)
    var window: WindowChoice
}

// MARK: - The timeline

struct ReadingsEntry: TimelineEntry {
    let date: Date
    let readings: MergedReadings
    var provider: ProviderID?
    var window: WindowChoice = .automatic
    var providerStyle: ProviderStyle = .ring
    var overviewStyle: OverviewStyle = .rings

    var item: MergedReadings.Item? {
        guard let provider else { return readings.items.first }
        return readings.items.first { $0.provider == provider }
    }

    /// Past a heartbeat and a half with no word from any Mac.
    var quiet: Bool { readings.freshness(now: date) != .current }
}

enum ReadingsTimeline {
    /// A fetch gets a few seconds; past that the cache stands in.
    static func readings() async -> MergedReadings {
        await ReadingsSync.fetch(within: 6)
    }

    /// An entry now and every quarter hour for two hours, so a window's reset
    /// and a Mac falling silent show on time without a fetch; then iOS is
    /// asked for a new timeline, which fetches again.
    static func entries(_ make: (Date) -> ReadingsEntry) -> Timeline<ReadingsEntry> {
        let now = Date()
        let dates = (0..<8).map { now.addingTimeInterval(Double($0) * 15 * 60) }
        return Timeline(entries: dates.map(make), policy: .after(now.addingTimeInterval(15 * 60)))
    }

    /// The gallery shows sample readings until the Macs have sent some; a
    /// widget the owner has placed shows the cache until its timeline comes.
    static func snapshotReadings(isPreview: Bool) -> MergedReadings {
        let cached = ReadingsCache.merged
        return isPreview && cached.items.isEmpty ? MergedReadings(CloudReadings.samples) : cached
    }

    static let placeholder = ReadingsEntry(date: .now, readings: MergedReadings(CloudReadings.samples))
}

struct ProviderTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ReadingsEntry { ReadingsTimeline.placeholder }

    func snapshot(for configuration: ProviderWidgetIntent, in context: Context) async -> ReadingsEntry {
        entry(.now, ReadingsTimeline.snapshotReadings(isPreview: context.isPreview), configuration)
    }

    func timeline(for configuration: ProviderWidgetIntent, in context: Context) async -> Timeline<ReadingsEntry> {
        let readings = await ReadingsTimeline.readings()
        return ReadingsTimeline.entries { entry($0, readings, configuration) }
    }

    private func entry(_ date: Date, _ readings: MergedReadings, _ configuration: ProviderWidgetIntent) -> ReadingsEntry {
        ReadingsEntry(
            date: date, readings: readings, provider: configuration.provider?.provider,
            window: configuration.window, providerStyle: configuration.style)
    }
}

struct OverviewTimeline: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ReadingsEntry { ReadingsTimeline.placeholder }

    func snapshot(for configuration: OverviewWidgetIntent, in context: Context) async -> ReadingsEntry {
        entry(.now, ReadingsTimeline.snapshotReadings(isPreview: context.isPreview), configuration)
    }

    func timeline(for configuration: OverviewWidgetIntent, in context: Context) async -> Timeline<ReadingsEntry> {
        let readings = await ReadingsTimeline.readings()
        return ReadingsTimeline.entries { entry($0, readings, configuration) }
    }

    private func entry(_ date: Date, _ readings: MergedReadings, _ configuration: OverviewWidgetIntent) -> ReadingsEntry {
        ReadingsEntry(date: date, readings: readings, window: configuration.window, overviewStyle: configuration.style)
    }
}

/// Spend needs no configuration: every provider with CLI logs behind it.
struct SpendTimeline: TimelineProvider {
    func placeholder(in context: Context) -> ReadingsEntry { ReadingsTimeline.placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ReadingsEntry) -> Void) {
        completion(ReadingsEntry(date: .now, readings: ReadingsTimeline.snapshotReadings(isPreview: context.isPreview)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingsEntry>) -> Void) {
        Task {
            let readings = await ReadingsTimeline.readings()
            completion(ReadingsTimeline.entries { ReadingsEntry(date: $0, readings: readings) })
        }
    }
}
