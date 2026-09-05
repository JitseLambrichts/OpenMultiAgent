import SwiftUI

/// Content surfaces stay solid on every macOS version. Glass is reserved for the
/// navigation layer (see `omaNavigationSurface`), never stacked on content.
struct OMACardSurface: ViewModifier {
    var isInteractive = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(OMAColor.surface)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        isInteractive ? Color.primary.opacity(0.18) : OMAColor.separator,
                        lineWidth: 1
                    )
            }
    }
}

extension View {
    func omaCard(interactive: Bool = false) -> some View {
        modifier(OMACardSurface(isInteractive: interactive))
    }

    /// The single availability-gated glass entry point. macOS 26 renders Liquid
    /// Glass; earlier systems use a native material with identical layout.
    @ViewBuilder
    func omaNavigationSurface() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 12, style: .continuous))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// Short, interruptible motion for selection and panel changes. Honors
    /// Reduce Motion by dropping to an immediate update.
    func omaPanelAnimation<Value: Equatable>(_ value: Value, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? nil : .smooth(duration: 0.25), value: value)
    }
}

/// Status is always text + symbol + color, so color is never the only signal.
struct StatusBadge: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
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
            }
        }
        .padding(12)
        .background(OMAColor.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(OMAColor.attention.opacity(0.22))
        }
        .accessibilityElement(children: .combine)
    }
}

extension AgentKind {
    var tint: Color {
        switch rawValue {
        case "claude": OMAColor.attention
        case "codex": OMAColor.positive
        case "gemini": OMAColor.accent
        default: OMAColor.accent
        }
    }
}
