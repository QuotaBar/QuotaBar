import SwiftUI
import ServiceManagement
import QuotaCore

// MARK: - Presentation

struct PresentationPane: View {
    @ObservedObject var store: UsageStore
    /// Re-read when a display comes or goes, so the picker lists what is
    /// actually there.
    @State private var screens = NSScreen.screens

    var body: some View {
        // Each place its own card and its own switch, as the desktop cards
        // below have: they used to be one choice, so the island and the dock
        // could not be on together — people who use several services wanted
        // two on the island and two more on the dock.
        SettingsCard(L10n.t("Notch island", "刘海岛")) {
            SettingToggle(
                L10n.t("Show at the notch", "在刘海显示"),
                caption: L10n.t(
                    "Providers either side of the notch at the top of the screen; hover to open the full panel.",
                    "在屏幕顶部刘海两侧显示服务商，悬停展开完整面板。"),
                isOn: Binding(get: { store.showsIsland }, set: { store.setShowsIsland($0) }))
            if store.showsIsland {
                SettingRow(
                    L10n.t("Per side", "每侧显示"),
                    caption: L10n.t(
                        "How many providers sit either side of the notch, in the order they are enabled. The glow, the flash and the auto-open only speak for these. Hover to open the full panel.",
                        "刘海两侧各显示几个服务商，按启用顺序排列。光晕、闪烁和自动弹出只针对这几个。悬停即从顶部展开完整面板。"))
                {
                    GlassSegmented(
                        options: [1, 2, 3].map { (value: $0, label: L10n.t("\($0)", "\($0) 个")) },
                        selection: store.islandSlots,
                        onSelect: { store.setIslandSlots($0) })
                }
                SettingToggle(
                    L10n.t("Glow", "光晕"), caption: L10n.t("A halo that turns amber or red near the limit, and a light that orbits the outline.", "轮廓外的柔光，接近上限时变琥珀或红色，另有一道光沿轮廓环绕。"),
                    isOn: Binding(
                        get: { store.experience.islandGlow },
                        set: { value in store.updateExperience { $0.islandGlow = value } }))
                SettingToggle(
                    L10n.t("Light always running", "光晕一直转"),
                    caption: L10n.t(
                        "Off, the light runs while a read is in flight, on hover and near a limit. Always running keeps a Mac busy: about 8% of a core for as long as the island is on screen.",
                        "关闭时只在读取数据、鼠标悬停和接近上限时转。一直转会让 Mac 一直忙着：刘海岛显示期间约占 8% 的单核。"),
                    isOn: Binding(
                        get: { store.experience.islandSweepAlways },
                        set: { value in store.updateExperience { $0.islandSweepAlways = value } }))
                .disabled(!store.experience.islandGlow)
                .opacity(!store.experience.islandGlow ? 0.45 : 1)
                SettingToggle(
                    L10n.t("Open when a limit nears", "越线时自动弹出"), caption: L10n.t("Opens for four seconds when a provider shown on the island crosses its warning.", "岛上显示的服务商第一次超过告警线时展开 4 秒。"),
                    isOn: Binding(
                        get: { store.experience.islandAutoPeek },
                        set: { value in store.updateExperience { $0.islandAutoPeek = value } }))
                SettingRow(L10n.t("Chart", "图表样式"), caption: L10n.t("⌘-click the open panel to cycle.", "在展开的面板上按住 ⌘ 点击也能切换。")) {
                    GlassSegmented(
                        options: IslandChartStyle.allCases.map { (value: $0, label: $0.displayName) },
                        selection: store.experience.islandChart,
                        onSelect: { value in store.updateExperience { $0.islandChart = value } })
                }
            }
        }

        SettingsCard(L10n.t("Edge dock", "边缘停靠条")) {
            SettingToggle(
                L10n.t("Show at the screen edge", "在屏幕边缘显示"),
                caption: L10n.t(
                    "A strip of rings against the left or right edge of the screen; reach the edge to open it.",
                    "贴在屏幕左侧或右侧边缘的一列圆环，鼠标移到边缘即展开。"),
                isOn: Binding(get: { store.showsDock }, set: { store.setShowsDock($0) }))
            if store.showsDock {
                SettingRow(
                    L10n.t("Docked edge", "停靠边缘"),
                    caption: L10n.t(
                        "Drag the dock up or down to move it; the position is remembered. Click a ring to open the panel for that provider.",
                        "上下拖动可移动停靠条，位置会被记住。点击圆环可打开该服务商的完整面板。"))
                {
                    GlassSegmented(
                        options: DockEdge.allCases.map { (value: $0, label: $0.displayName) },
                        selection: store.dockEdge,
                        onSelect: { store.setDockEdge($0) })
                }
                SettingToggle(
                    L10n.t("Keep the dock visible", "常驻显示（不自动隐藏）"),
                    isOn: Binding(
                        get: { store.dockAlwaysVisible },
                        set: { store.setDockAlwaysVisible($0) }))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }

        // Only a question on a Mac with more than one display.
        if screens.count > 1 {
            SettingsCard(L10n.t("Screen", "屏幕")) {
                SettingRow(
                    L10n.t("Show on", "显示在"),
                    caption: L10n.t(
                        "Automatic follows the menu bar's screen; the island, the screen with the notch. Desktop cards go along.",
                        "自动跟随菜单栏所在的屏幕，刘海岛跟随带刘海的屏幕。桌面卡片同屏。"))
                {
                    GlassSegmented(
                        options: ScreenChoice.options,
                        selection: ScreenChoice.selection,
                        onSelect: { store.setDisplayScreen($0) })
                }
            }
        }

        SettingsCard(
            L10n.t("Which limit each place shows", "各处显示的额度"),
            help: L10n.t(
                "The menu bar, the island and the dock each show one figure for a provider, and each can stand for a different limit — the 5-hour limit in the menu bar and the week on the dock, say. The menu bar goes with the card in its panel: double-click a limit on the card and the icon and the card's ring both follow it. Automatic is the fullest of the plan's own limits; an allowance beside the plan — Cursor's Grok Bot, Codex's reserve — only counts when you pick it.",
                "菜单栏、刘海岛和停靠条各用一个数字代表一个服务商，可以分别代表不同的额度，比如菜单栏看 5 小时、停靠条看每周。菜单栏跟它下拉面板里的卡片是一起的：在卡片上双击某个额度，菜单栏图标和卡片圆环就都按它显示。「自动」取套餐自身额度里用得最满的那个；套餐之外的附加额度（Cursor 的 Grok Bot、Codex 的备用额度）只有你亲自选了才算。"))
        {
            if store.enabled.isEmpty {
                SettingFootnote(L10n.t("No providers are on.", "还没有开启服务商。"))
            } else {
                VStack(spacing: Design.space1) {
                    HStack(spacing: Design.space2) {
                        Spacer(minLength: 0)
                        ForEach(FigurePlace.allCases) { place in
                            Text(place.displayName)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: PlaceWindowRow.columnWidth, alignment: .leading)
                        }
                    }
                    ForEach(store.enabled) { id in
                        PlaceWindowRow(store: store, id: id)
                    }
                    // The overview reading is the fullest limit of all, by
                    // name and for the alerts' sake, so a pick has nothing
                    // to move there; say where it does.
                    if store.selected == nil, store.menuBarIconMode != .text {
                        SettingFootnote(L10n.t(
                            "The menu bar is on Automatic, which reads the fullest limit of every provider, so the first column shows on the icon once it follows one provider (right-click the icon › Show in Menu Bar) or is set to Marks and figures. The card's ring follows it either way.",
                            "菜单栏现在是「自动」，取所有服务商里用得最满的额度，所以第一列要在图标只看某一个服务商（右键图标 ›「显示在菜单栏」）或图标设为「logo 加数字」时才在图标上看得出来；卡片圆环不受影响，始终按它显示。"))
                    }
                }
            }
        }

        SettingsCard(
            L10n.t("What each place shows", "各处显示的服务商"),
            help: L10n.t(
                "Hiding a provider only takes it off that place: it is still read, still alerts, and still counts in spend. Turning it off in Providers stops reading it.",
                "隐藏只是不在那里显示：该服务商仍会读取数据、发提醒、计入花费。在「服务商」里停用才会停止读取。"))
        {
            if store.showsIsland && store.showsDock {
                SettingFootnote(L10n.t(
                    "With the island and the dock both on, split your services between them here — say Claude and Codex on the island, Cursor and Gemini on the dock.",
                    "刘海岛和停靠条都打开时，可以在这里把服务商分开放，比如刘海岛放 Claude、Codex，停靠条放 Cursor、Gemini。"))
            }
            if store.enabled.isEmpty {
                SettingFootnote(L10n.t("No providers are on.", "还没有开启服务商。"))
            } else {
                VStack(spacing: Design.space1) {
                    ForEach(store.enabled) { id in
                        SurfaceVisibilityRow(store: store, id: id)
                    }
                }
            }
        }

        SettingsCard(
            L10n.t("Desktop cards", "桌面卡片"),
            help: L10n.t(
                "Cards sit on the desktop, below your windows, unless kept above. Drag one to move it, double-click for the menu panel, right-click to change its style, size or provider, or to remove it.",
                "卡片默认位于桌面、在窗口之下，可改为置顶。拖动移动位置，双击打开下拉面板，右键可更换样式、尺寸、服务商或删除。"))
        {
            SettingToggle(
                L10n.t("Show on the desktop", "在桌面显示"),
                isOn: Binding(
                    get: { store.widgetEnabled },
                    set: { store.setWidgetEnabled($0) }))
            ForEach(Array(store.experience.deskCards.enumerated()), id: \.element.id) { index, card in
                DeskCardSettingsRow(store: store, card: card, number: index + 1)
                    .disabled(!store.widgetEnabled)
                    .opacity(store.widgetEnabled ? 1 : 0.45)
            }
            SettingRow(L10n.t("Add", "添加")) {
                HStack(spacing: Design.space2) {
                    GlassMenuButton(
                        title: L10n.t("Add a card", "添加卡片"),
                        systemImage: "plus",
                        items: DeskCardStyle.allCases.map { style in
                            (style.displayName, { store.addDeskCard(style: style, near: store.experience.deskCards.last) })
                        })
                    Button(L10n.t("Restore the default pair", "恢复默认两张")) {
                        store.updateExperience { $0.deskCards = DeskCard.defaults(provider: nil) }
                        if !store.widgetEnabled { store.setWidgetEnabled(true) }
                        store.widgetRevision &+= 1
                    }
                    .glassAction()
                    Spacer(minLength: 0)
                }
            }
            SettingToggle(
                L10n.t("Keep above other windows", "置于其他窗口之上"),
                isOn: Binding(
                    get: { store.widgetAlwaysOnTop },
                    set: { store.setWidgetAlwaysOnTop($0) }))
                .disabled(!store.widgetEnabled)
                .opacity(store.widgetEnabled ? 1 : 0.45)
            SettingToggle(
                L10n.t("Classic card: closest to the limit first", "经典样式按紧迫度排序"),
                isOn: Binding(
                    get: { store.experience.widgetSortsByUrgency },
                    set: { value in store.updateExperience { $0.widgetSortsByUrgency = value } }))
        }
    }
}

/// One desktop card in Settings: its style, size and subject, and a way to
/// remove it.
private struct DeskCardSettingsRow: View {
    @ObservedObject var store: UsageStore
    let card: DeskCard
    let number: Int

    var body: some View {
        SettingRow(L10n.t("Card \(number)", "卡片 \(number)")) {
            HStack(spacing: Design.space2) {
                GlassPopUp(
                    options: DeskCardStyle.allCases.map { (value: $0, label: $0.displayName) },
                    selection: card.style,
                    onSelect: { style in store.updateDeskCard(card.id) { $0.style = style } })
                .frame(width: 118)

                GlassSegmented(
                    options: DeskCardSize.allCases.map { (value: $0, label: $0.shortName) },
                    selection: card.size,
                    onSelect: { size in store.updateDeskCard(card.id) { $0.size = size } })
                .frame(width: 120)

                if card.style.readsLogs {
                    GlassPopUp(
                        options: [(value: CostSource?.none, label: L10n.t("Every CLI", "全部来源"))]
                            + CostSource.allCases.map { (value: Optional($0), label: $0.displayName) },
                        selection: card.source,
                        onSelect: { source in store.updateDeskCard(card.id) { $0.source = source } })
                    .frame(width: 128)
                } else {
                    GlassPopUp(
                        options: [(
                            value: ProviderID?.none,
                            label: card.style.singleProvider
                                ? L10n.t("Follow menu bar", "跟随菜单栏")
                                : L10n.t("Every provider", "全部服务商"))]
                            // A card pinned to a provider since switched off
                            // still names it, rather than showing a blank.
                            + (store.enabled + [card.provider].compactMap { $0 }.filter { !store.enabled.contains($0) })
                                .map { (value: Optional($0), label: $0.displayName) },
                        selection: card.provider,
                        onSelect: { provider in store.updateDeskCard(card.id) { $0.provider = provider } })
                    .frame(width: 128)
                }

                Button {
                    store.removeDeskCard(card.id)
                } label: {
                    Image(systemName: "trash")
                }
                .glassAction(compact: true)
                .help(L10n.t("Remove this card", "删除这张卡片"))
                Spacer(minLength: 0)
            }
        }
    }
}

/// One enabled provider and the limit its figure stands for in each place
/// that shows a single figure. A provider with one limit has nothing to
/// choose between, and says so rather than offering three menus of one.
private struct PlaceWindowRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    private var windows: [UsageWindow] {
        store.states[id]?.snapshot?.windows.filter { $0.usedPercent != nil } ?? []
    }

    /// What stands in for the menus when there is nothing to choose between.
    /// No reading is not no limits: a provider still loading, or one whose
    /// read failed, says that, and keeps whatever was picked for it.
    private var note: String {
        guard store.states[id]?.snapshot != nil else {
            return store.isLoading(id) ? L10n.t("Loading…", "加载中…") : L10n.t("No reading yet", "还没有读数")
        }
        guard let only = windows.first else {
            return L10n.t("No limits with a figure", "没有带百分比的额度")
        }
        return L10n.t("One limit: \(only.menuName)", "只有一个额度：\(only.menuName)")
    }

    var body: some View {
        HStack(spacing: Design.space2) {
            ProviderGlyph(id: id, size: 16)
                .frame(width: 20)
            Text(id.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: Design.space2)
            if windows.count < 2 {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(FigurePlace.allCases) { place in
                    GlassPopUp(
                        options: [(value: String?.none, label: L10n.t("Automatic", "自动"))]
                            + windows.map { (value: Optional($0.id), label: $0.menuName) },
                        selection: windows.contains { $0.id == store.pickedHeadlineWindow(for: id, on: place) }
                            ? store.pickedHeadlineWindow(for: id, on: place) : nil,
                        onSelect: { store.setHeadlineWindow($0, for: id, on: place) })
                    .frame(width: PlaceWindowRow.columnWidth)
                }
            }
        }
        .frame(minHeight: 28)
    }

    static let columnWidth: CGFloat = 128
}

/// One enabled provider and the places it is shown: a chip per surface, lit
/// where it shows, dimmed where it is hidden.
private struct SurfaceVisibilityRow: View {
    @ObservedObject var store: UsageStore
    let id: ProviderID

    var body: some View {
        HStack(spacing: Design.space2) {
            ProviderGlyph(id: id, size: 16)
                .frame(width: 20)
            Text(id.displayName)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: Design.space2)
            ForEach(DisplaySurface.allCases) { surface in
                let shown = !store.experience.isHidden(id, on: surface)
                Button {
                    withAnimation(Motion.animation(.easeOut(duration: 0.15))) {
                        store.setHidden(shown, id, on: surface)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: shown ? "eye" : "eye.slash")
                            .font(.system(size: 10, weight: .medium))
                        Text(surface.displayName)
                            .font(.system(size: 11, weight: shown ? .medium : .regular))
                    }
                    .foregroundStyle(shown ? Design.ink : Color.secondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(shown ? Design.accent : Design.fieldFill))
                    .overlay(
                        Capsule().strokeBorder(shown ? Color.clear : Design.glassEdge, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(shown
                    ? L10n.t("Shown in \(surface.displayName) — click to hide", "显示在\(surface.displayName) · 点击隐藏")
                    : L10n.t("Hidden from \(surface.displayName) — click to show", "已在\(surface.displayName)隐藏 · 点击显示"))
            }
        }
        .frame(minHeight: 30)
    }
}
