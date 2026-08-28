import AppKit
import SwiftUI
import QuotaCore

// MARK: - Liquid Glass

/// The settings window is the one surface that opts into Liquid Glass.
///
/// `glassEffect` ships in macOS 26 and the deployment target is macOS 14, so
/// every call site goes through here rather than scattering `if #available`
/// through the layout code. Below 26 the fallback is a frosted material with a
/// specular hairline, which is a different look but the same visual weight —
/// the layout does not shift between the two.
///
/// Scope is deliberate. The menu panel, the edge dock, the notch island and the
/// desktop widget stay on the flat `Design` surfaces: they sit over arbitrary
/// wallpaper and have to carry their own contrast, and glass there would put
/// the user's wallpaper behind the numbers the app exists to show. A settings
/// window is always over the desktop *and* always in front, so it can afford it.
enum GlassKit {
    /// True when the real thing is available, rather than the frosted stand-in.
    static var isSupported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

@available(macOS 26.0, *)
private struct LiquidGlassSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color?
    let interactive: Bool

    private var glass: Glass {
        var value = Glass.regular
        if let tint { value = value.tint(tint) }
        if interactive { value = value.interactive() }
        return value
    }

    func body(content: Content) -> some View {
        content.glassEffect(glass, in: .rect(cornerRadius: radius))
    }
}

/// Pre-26 stand-in: a material fill plus a one-pixel specular edge.
///
/// This is the one place the project's "a fill *or* a border, never both" rule
/// is broken on purpose — a glass edge is what separates a translucent card
/// from the translucent thing behind it, and without it the cards dissolve.
private struct FrostedSurface: ViewModifier {
    let radius: CGFloat
    let tint: Color?

    func body(content: Content) -> some View {
        content.background {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(.regularMaterial)
                .overlay { shape.fill(tint?.opacity(0.16) ?? .clear) }
                .overlay { shape.strokeBorder(Design.glassEdge, lineWidth: 1) }
        }
    }
}

/// Off-screen rendering falls back to flat surfaces.
///
/// Glass and vibrancy are both drawn by AppKit at composite time; `ImageRenderer`
/// paints neither, so a snapshot of the real thing would come out as empty
/// rectangles and the layout — the reason the snapshot exists — would be
/// invisible. The flat stand-in has the same metrics.
private struct GlassDisabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassDisabled: Bool {
        get { self[GlassDisabledKey.self] }
        set { self[GlassDisabledKey.self] = newValue }
    }
}

private struct GlassSurface: ViewModifier {
    @Environment(\.glassDisabled) private var disabled

    let radius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if disabled {
            content.background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Design.surface)
            }
        } else if #available(macOS 26.0, *) {
            content.modifier(
                LiquidGlassSurface(radius: radius, tint: tint, interactive: interactive))
        } else {
            content.modifier(FrostedSurface(radius: radius, tint: tint))
        }
    }
}

private struct GlassGroup: ViewModifier {
    @Environment(\.glassDisabled) private var disabled

    let spacing: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if !disabled, #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// A glass card. `tint` colours the glass itself, not the content.
    func glassSurface(
        radius: CGFloat = Design.radiusPanel,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(GlassSurface(radius: radius, tint: tint, interactive: interactive))
    }

    /// Groups sibling glass shapes so they blend into each other instead of
    /// each refracting the backdrop on its own. A no-op before macOS 26.
    func glassGroup(spacing: CGFloat = Design.space3) -> some View {
        modifier(GlassGroup(spacing: spacing))
    }

    /// Button chrome to match the surfaces.
    @ViewBuilder
    func glassAction(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
    }
}

// MARK: - Window chrome

/// Vibrant backdrop. `behindWindow` blending is what makes the glass above it
/// have something to refract.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Runs the content to the top edge of the settings window.
///
/// `Settings { }` hands out no `NSWindow`, so this rides along in the view tree
/// and configures whichever window it lands in, once. Everything it sets is a
/// no-op if the window never materialises — the snapshot renderer has no window
/// at all and must not trap here.
struct WindowChrome: NSViewRepresentable {
    final class Coordinator {
        var configured = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(view, context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(view, context.coordinator)
    }

    private func apply(_ view: NSView, _ coordinator: Coordinator) {
        guard !coordinator.configured else { return }
        DispatchQueue.main.async {
            guard !coordinator.configured, let window = view.window else { return }
            coordinator.configured = true
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            // Without this the system still draws a hairline under the
            // titlebar, which cuts across the sidebar and the first card.
            window.titlebarSeparatorStyle = .none
        }
    }
}

// MARK: - Form primitives

/// One labelled setting. The label column is a fixed width so every control in
/// the window starts at the same x — the difference between a form and a stack
/// of unrelated widgets.
struct SettingRow<Control: View>: View {
    private let title: String
    private let caption: String?
    private let control: Control

    init(_ title: String, caption: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.caption = caption
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: Design.labelColumn, alignment: .leading)
            .padding(.top, 4)

            control
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A switch row. The switch sits at the far right of the card, which is where
/// macOS puts it — inline after the label reads as a stray control, and with a
/// label column it also means saying the same thing twice.
struct SettingToggle: View {
    private let title: String
    private let caption: String?
    private let isOn: Binding<Bool>

    init(_ title: String, caption: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.caption = caption
        self.isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top, spacing: Design.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Design.space3)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled glass card. Sections are cards so a long pane still reads as a set
/// of decisions rather than one undifferentiated list.
struct SettingsCard<Content: View>: View {
    private let title: String?
    private let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.space3) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(Design.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(radius: Design.radiusPanel)
    }
}

/// Explanatory text under a control. Its own type so the size and colour cannot
/// drift between sections.
struct SettingFootnote: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Segmented control drawn in the app's own accent rather than AppKit's.
///
/// Replaces `.pickerStyle(.segmented)` everywhere in this window: the system
/// control paints its selection in the *system* accent, which fights the eleven
/// provider brand colours the rest of the app is careful to stay out of the way
/// of. The selection block slides, so the change is legible when it is driven
/// from somewhere other than a click.
struct GlassSegmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Value
    let onSelect: (Value) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: Design.fieldHeight - 6)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Design.radiusTile - 2, style: .continuous)
                                    .fill(Design.accent)
                                    .matchedGeometryEffect(id: "selection", in: namespace)
                            }
                        }
                        .foregroundStyle(isSelected ? Design.ink : Color.primary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: Design.radiusTile + 1, style: .continuous)
                .fill(Design.surfaceStrong))
        .animation(.snappy(duration: 0.22), value: selection)
    }
}

/// Credential field: monospaced, fixed height, optional reveal toggle.
///
/// Not `.roundedBorder` — that control is 22pt tall with a hard bezel and reads
/// as a different era from everything around it.
struct GlassTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure: Bool = false
    var reveal: Binding<Bool>?
    var monospaced: Bool = true
    var onSubmit: () -> Void = {}

    private var isMasked: Bool {
        guard secure else { return false }
        return !(reveal?.wrappedValue ?? false)
    }

    var body: some View {
        HStack(spacing: Design.space2) {
            Group {
                if isMasked {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 12, design: monospaced ? .monospaced : .default))
            .onSubmit(onSubmit)

            if let reveal {
                Button {
                    reveal.wrappedValue.toggle()
                } label: {
                    Image(systemName: reveal.wrappedValue ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(reveal.wrappedValue
                    ? L10n.t("Hide", "隐藏")
                    : L10n.t("Reveal", "显示"))
            }
        }
        .padding(.horizontal, Design.space3)
        .frame(height: Design.fieldHeight)
        .background {
            let shape = RoundedRectangle(cornerRadius: Design.radiusField, style: .continuous)
            shape
                .fill(Design.fieldFill)
                .overlay { shape.strokeBorder(Design.glassEdge, lineWidth: 1) }
        }
    }
}

/// Status pill — "ready", "not configured", "off".
struct StatusPill: View {
    let text: String
    let tone: Tone

    enum Tone {
        case ready
        case attention
        case idle
    }

    private var colour: Color {
        switch tone {
        case .ready: return .green
        case .attention: return .orange
        case .idle: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: Design.space1 + 1) {
            Circle()
                .fill(colour)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(tone == .idle ? Color.secondary : Color.primary.opacity(0.8))
        }
        .padding(.horizontal, Design.space2)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(colour.opacity(tone == .idle ? 0.08 : 0.14)))
    }
}

// MARK: - Sidebar rail

/// The sidebar's selection: a hairline rail with a lit segment that travels to
/// the selected row.
///
/// Three layers are what make it read as light rather than as a painted tick,
/// and dropping any one of them collapses the effect:
///
/// - the rail, faded out at both ends so it has no hard start or stop
/// - the segment, faded the same way along its own length
/// - a blurred bloom behind the segment, plus a horizontal bleed spilling right
///   under the label
///
/// The rail is drawn once for the whole list and sits *behind* the rows, so the
/// bleed falls under the label the way real light would. It cannot belong to a
/// row: the lit segment's whole job is to travel between them.
///
/// The travel overshoots and settles — the original is
/// `cubic-bezier(0.37, 1.95, 0.66, 0.56)`, where the 1.95 is the overshoot.
/// That is a spring, so it is written as one rather than approximated with a
/// timing curve.
struct SidebarRail: View {
    let count: Int
    let index: Int
    var rowHeight: CGFloat = Design.sidebarRow
    var tint: Color = Design.sidebarGlow

    private var total: CGFloat { rowHeight * CGFloat(count) }

    var body: some View {
        ZStack(alignment: .top) {
            rail
            glider.offset(y: rowHeight * CGFloat(index))
        }
        // Width 1 so the glow overflows instead of widening the sidebar; the
        // rows are laid out against the rail, not against its bloom.
        .frame(width: 1, height: total, alignment: .top)
        .animation(.spring(response: 0.42, dampingFraction: 0.58), value: index)
        .allowsHitTesting(false)
    }

    private var rail: some View {
        Rectangle()
            .fill(LinearGradient(
                colors: [.clear, tint.opacity(0.22), .clear],
                startPoint: .top,
                endPoint: .bottom))
            .frame(width: 1, height: total)
    }

    private var glider: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(LinearGradient(
                    colors: [tint.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: .trailing))
                .frame(width: 132, height: rowHeight)
                // Feathered vertically as well as horizontally. A hard top and
                // bottom edge on the bleed reads as a rectangle someone drew,
                // not as light falling off the rail.
                .mask(LinearGradient(
                    colors: [.clear, .white, .white, .clear],
                    startPoint: .top,
                    endPoint: .bottom))

            Capsule()
                .fill(tint.opacity(0.85))
                .frame(width: 3, height: rowHeight * 0.6)
                .blur(radius: 7)
                .offset(x: -1)

            Rectangle()
                .fill(LinearGradient(
                    colors: [.clear, tint, .clear],
                    startPoint: .top,
                    endPoint: .bottom))
                .frame(width: 1.5, height: rowHeight)
        }
        .frame(width: 1, height: rowHeight, alignment: .leading)
    }
}
