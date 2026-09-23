import SwiftUI

// MARK: - Cards

/// Cards are soft, borderless blocks on the canvas. Depth comes from the
/// stacked greys (canvas → surface → elevated), never from strokes.
struct OMACardSurface: ViewModifier {
    var isInteractive = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(OMAColor.surface)
            )
            .overlay {
                if isInteractive {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                }
            }
    }
}

extension View {
    func omaCard(interactive: Bool = false) -> some View {
        modifier(OMACardSurface(isInteractive: interactive))
    }

    /// A smaller block that sits inside a card (rows, chips, inner panels).
    func omaInnerCard(cornerRadius: CGFloat = 14) -> some View {
        background(OMAColor.elevated, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// Short, interruptible motion for selection and panel changes. Honors
    /// Reduce Motion by dropping to an immediate update.
    func omaPanelAnimation<Value: Equatable>(_ value: Value, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? nil : .smooth(duration: 0.25), value: value)
    }
}

// MARK: - Buttons

/// Lime pill: the one prominent action on a screen.
struct OMAPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(OMAColor.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(OMAColor.accent, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// Dark pill for secondary actions next to a primary one.
struct OMASecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(configuration.isPressed ? OMAColor.raised : OMAColor.elevated, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
    }
}

/// Round icon button, as used next to the search field in the reference.
struct OMAIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var size: CGFloat = 36

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? OMAColor.raised : OMAColor.elevated, in: Circle())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Circle())
    }
}

extension ButtonStyle where Self == OMAPrimaryButtonStyle {
    static var omaPrimary: OMAPrimaryButtonStyle { OMAPrimaryButtonStyle() }
}

extension ButtonStyle where Self == OMASecondaryButtonStyle {
    static var omaSecondary: OMASecondaryButtonStyle { OMASecondaryButtonStyle() }
}

extension ButtonStyle where Self == OMAIconButtonStyle {
    static var omaIcon: OMAIconButtonStyle { OMAIconButtonStyle() }
}

/// Round container for a `Menu` so it lines up with icon buttons.
struct OMAIconMenu<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        Menu {
            content
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 36, height: 36)
        .background(OMAColor.elevated, in: Circle())
        .contentShape(Circle())
        .help(title)
        .accessibilityLabel(title)
    }
}

// MARK: - Fields and pickers

/// Pill search field with a leading magnifier.
struct OMASearchField: View {
    let prompt: String
    @Binding var text: String
    var isBusy = false
    var focus: FocusState<Bool>.Binding? = nil
    var accessibilityLabel: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            field
                .textFieldStyle(.plain)
                .font(.subheadline)
                .accessibilityLabel(accessibilityLabel ?? prompt)
            if isBusy {
                Image(systemName: "progress.indicator")
                    .symbolEffect(.variableColor.iterative, isActive: true)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Searching")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
        .background(OMAColor.elevated, in: Capsule())
    }

    @ViewBuilder
    private var field: some View {
        if let focus {
            TextField(prompt, text: $text).focused(focus)
        } else {
            TextField(prompt, text: $text)
        }
    }
}

/// Segmented control as a pill strip; the selected segment is a lime pill.
struct OMAPillPicker<Option: Hashable & Identifiable>: View {
    let options: [Option]
    @Binding var selection: Option
    var iconOnly = false
    var accessibilityLabel: String? = nil
    let title: (Option) -> String
    let symbol: (Option) -> String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: symbol(option))
                            .font(.system(size: 12, weight: .semibold))
                        if !iconOnly {
                            Text(title(option))
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .foregroundStyle(isSelected ? OMAColor.onAccent : Color.secondary)
                    .padding(.horizontal, iconOnly ? 10 : 14)
                    .frame(height: 30)
                    .background(isSelected ? OMAColor.accent : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(title(option))
                .accessibilityLabel(title(option))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(OMAColor.elevated, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel ?? "")
    }
}

// MARK: - Page chrome

/// Large page title with the muted one-line subtitle from the reference.
struct PageTitle: View {
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 26, weight: .bold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Round accent icon (lime disc, dark glyph) for headers and cards.
struct AccentDisc: View {
    let symbol: String
    var size: CGFloat = 44
    var tint: Color = OMAColor.accent

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(OMAColor.onAccent)
            .frame(width: size, height: size)
            .background(tint, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Status is always text + symbol + color, so color is never the only signal.
struct StatusBadge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel("Status: \(text)")
    }
}

/// Section header used by cockpit and workspace panels.
struct PanelHeader<Trailing: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var trailing: Trailing

    init(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.symbol = symbol
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            // Only the symbol and title merge; trailing controls stay separate so
            // a header never reads as a button under VoiceOver.
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(OMAColor.accent)
                Text(title)
                    .font(.headline)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing
        }
    }
}

/// Inline, non-blocking notice for recoverable errors at the affected item.
struct InlineNotice: View {
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(_ message: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OMAColor.attention)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.omaSecondary)
            }
        }
        .padding(14)
        .background(OMAColor.attention.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension AgentKind {
    var tint: Color {
        switch rawValue {
        case "claude": OMAColor.attention
        case "codex": OMAColor.positive
        case "gemini": Color(red: 140 / 255, green: 180 / 255, blue: 255 / 255)
        default: OMAColor.accent
        }
    }
}
