import QuotaModel
import SwiftUI
import WidgetKit

@main
struct QuotaWidgets: WidgetBundle {
    var body: some Widget {
        ProviderWidget()
        OverviewWidget()
        SpendWidget()
    }
}

/// One provider. Small is a square — ring, two rings, stepped bars or a big
/// number, set in the widget; medium runs the full width with every limit;
/// large adds spend and a month of usage. On the lock screen: a gauge, two
/// rings or a number; two bars; or a line.
struct ProviderWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "provider", intent: ProviderWidgetIntent.self, provider: ProviderTimeline()) { entry in
            FamilyReader { ProviderWidgetView(entry: entry, family: $0) }
                .containerBackground(Color.widgetSurface, for: .widget)
        }
        .configurationDisplayName(L10n.t("Provider", "单个服务商"))
        .description(L10n.t(
            "One provider's limits. Edit the widget to pick the provider, the limit and the style.",
            "一个服务商的额度。编辑小组件可以选服务商、额度和样式。"))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ])
    }
}

/// Every provider, in the cards' order: rings, stepped bars or figures.
struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "overview", intent: OverviewWidgetIntent.self, provider: OverviewTimeline()) { entry in
            FamilyReader { OverviewWidgetView(entry: entry, family: $0) }
                .containerBackground(Color.widgetSurface, for: .widget)
        }
        .configurationDisplayName(L10n.t("Overview", "总览"))
        .description(L10n.t(
            "Every provider your Mac reads, as rings, stepped bars or figures.",
            "Mac 读到的所有服务商，可选圆环、格子条或数字样式。"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

/// Today's spend and the month's, across providers.
struct SpendWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "spend", provider: SpendTimeline()) { entry in
            FamilyReader { SpendWidgetView(entry: entry, family: $0) }
                .containerBackground(Color.widgetSurface, for: .widget)
        }
        .configurationDisplayName(L10n.t("Spend", "花费"))
        .description(L10n.t(
            "What today and the last 30 days cost, from your Mac's CLI logs.",
            "今日和近 30 天花了多少，来自 Mac 上的 CLI 日志。"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Hands the placed widget's size to a view that takes it as a parameter.
private struct FamilyReader<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    @ViewBuilder let content: (WidgetFamily) -> Content

    var body: some View { content(family) }
}

