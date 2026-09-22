#if DEBUG
import QuotaModel
import SwiftUI
import WidgetKit

/// Every widget style at its real size on one page, from the sample
/// readings: launched with `-QuotaBarWidgetGallery`. Placing each widget on
/// a home screen and editing it into each style is the only other way to
/// see them, and it takes minutes per look. Debug builds only.
struct WidgetGallery: View {
    private let readings = MergedReadings(CloudReadings.samples)
    /// `-QuotaBarWidgetGallery overview` (or `provider`, `lock`) shows one
    /// part, so a screenshot can land on it without scrolling.
    private let part: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-QuotaBarWidgetGallery"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    private func shows(_ name: String) -> Bool { part == nil || part == name }

    /// `-QuotaBarLight`: the widgets as a light-mode home screen draws them.
    private let light = ProcessInfo.processInfo.arguments.contains("-QuotaBarLight")

    // iPhone 16/17 Pro widget sizes, in points.
    private let small = CGSize(width: 170, height: 170)
    private let medium = CGSize(width: 364, height: 170)
    private let large = CGSize(width: 364, height: 382)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if shows("provider") { providerParts }
                if shows("overview") { overviewParts }
                if shows("lock") { lockParts }
                if part == "logos" { logoParts }
            }
            .padding(16)
        }
        .background(light ? Color(white: 0.86) : Color(white: 0.16))
        .environment(\.colorScheme, light ? .light : .dark)
    }

    @ViewBuilder
    private var providerParts: some View {
                title("单个服务商 · 小")
                LazyVGrid(columns: [GridItem(.fixed(small.width)), GridItem(.fixed(small.width))], spacing: 16) {
                    ForEach(ProviderStyle.allCases, id: \.self) { style in
                        tile(small) { ProviderWidgetView(entry: provider(style), family: .systemSmall) }
                    }
                }
                title("单个服务商 · 中（通栏）")
                ForEach(ProviderStyle.allCases, id: \.self) { style in
                    tile(medium) { ProviderWidgetView(entry: provider(style), family: .systemMedium) }
                }
                title("单个服务商 · 大")
                ForEach([ProviderStyle.ring, .dualRing, .bars], id: \.self) { style in
                    tile(large) { ProviderWidgetView(entry: provider(style), family: .systemLarge) }
                }
    }

    @ViewBuilder
    private var overviewParts: some View {
                title("总览 · 小")
                LazyVGrid(columns: [GridItem(.fixed(small.width)), GridItem(.fixed(small.width))], spacing: 16) {
                    ForEach(OverviewStyle.allCases, id: \.self) { style in
                        tile(small) { OverviewWidgetView(entry: overview(style), family: .systemSmall) }
                    }
                    tile(small) { SpendWidgetView(entry: overview(.rings), family: .systemSmall) }
                }
                title("总览 · 中")
                ForEach(OverviewStyle.allCases, id: \.self) { style in
                    tile(medium) { OverviewWidgetView(entry: overview(style), family: .systemMedium) }
                }
                tile(medium) { SpendWidgetView(entry: overview(.rings), family: .systemMedium) }
                title("总览 · 大")
                ForEach(OverviewStyle.allCases, id: \.self) { style in
                    tile(large) { OverviewWidgetView(entry: overview(style), family: .systemLarge) }
                }
    }

    @ViewBuilder
    private var lockParts: some View {
                title("锁屏")
                HStack(spacing: 16) {
                    ForEach([ProviderStyle.ring, .dualRing, .number], id: \.self) { style in
                        ProviderWidgetView(entry: provider(style), family: .accessoryCircular)
                            .frame(width: 72, height: 72)
                    }
                }
                HStack(spacing: 16) {
                    ProviderWidgetView(entry: provider(.bars), family: .accessoryRectangular)
                        .frame(width: 172, height: 76)
                    ProviderWidgetView(entry: provider(.number), family: .accessoryRectangular)
                        .frame(width: 172, height: 76)
                }
                OverviewWidgetView(entry: overview(.list), family: .accessoryRectangular)
                    .frame(width: 172, height: 76)
                ProviderWidgetView(entry: provider(.ring), family: .accessoryInline)
    }

    /// Every provider's mark as the phone draws it, on the card fill.
    private var logoParts: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 16) {
            ForEach(ProviderID.allCases) { id in
                VStack(spacing: 6) {
                    ProviderMark(id: id, size: 32)
                    Text(id.displayName).font(.caption2).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func provider(_ style: ProviderStyle) -> ReadingsEntry {
        ReadingsEntry(date: .now, readings: readings, provider: .claude, providerStyle: style)
    }

    private func overview(_ style: OverviewStyle) -> ReadingsEntry {
        ReadingsEntry(date: .now, readings: readings, overviewStyle: style)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.headline).padding(.top, 8)
    }

    /// A home-screen widget: its size, the system's 16pt margins, black.
    private func tile<Content: View>(_ size: CGSize, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(width: size.width, height: size.height)
            .background(Color.widgetSurface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

extension ProviderStyle: CaseIterable {
    static var allCases: [ProviderStyle] { [.ring, .dualRing, .bars, .number] }
}

extension OverviewStyle: CaseIterable {
    static var allCases: [OverviewStyle] { [.rings, .list, .figures] }
}
#endif
