import SwiftUI

/// Promotion always opens as a preview. Apply is the only tinted action and is
/// unavailable until a preview succeeded.
struct PromotionReviewView: View {
    let state: PromotionState
    let sessionTitle: String
    let onApply: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Review Knowledge")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(.secondary)
            }

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                statusLine
                Spacer()
                Button("Sluit", action: onClose)
                    .keyboardShortcut(.cancelAction)
                switch state {
                case .preview:
                    Button("Pas toe", systemImage: "checkmark.seal", action: onApply)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .tint(OMAColor.accent)
                case .failed:
                    Button("Probeer opnieuw", systemImage: "arrow.clockwise", action: onRetry)
                        .buttonStyle(.borderedProminent)
                        .tint(OMAColor.accent)
                default:
                    EmptyView()
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 560)
        .background(OMAColor.canvas)
    }

    private var subtitle: String {
        switch state {
        case .preview(_, let count): "\(count) kandidaat-record(s) uit “\(sessionTitle)”. Niets wordt weggeschreven tot je toepast."
        case .applying: "Kennis wordt weggeschreven…"
        case .applied(let files): "\(files.count) bestand(en) bijgewerkt onder .oma/docs."
        case .failed(let message, _): message
        case .extracting: "Kennis wordt geëxtraheerd uit het transcript…"
        case .idle: "Nog geen preview."
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .preview(let diff, _):
            DiffText(diff: diff)
        case .applied(let files):
            List(files, id: \.self) { file in
                Label(file, systemImage: "doc.text")
                    .font(.callout.monospaced())
            }
            .scrollContentBackground(.hidden)
        case .extracting, .applying:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message, _):
            ContentUnavailableView {
                Label("Promotie mislukt", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .idle:
            ContentUnavailableView("Geen preview", systemImage: "doc.text.magnifyingglass")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .applied:
            StatusBadge(text: "Toegepast", symbol: "checkmark.circle.fill", color: OMAColor.positive)
        case .applying, .extracting:
            StatusBadge(text: "Bezig", symbol: "progress.indicator", color: OMAColor.accent)
        case .failed:
            StatusBadge(text: "Mislukt", symbol: "xmark.octagon", color: OMAColor.negative)
        case .preview:
            StatusBadge(text: "Preview", symbol: "eye", color: OMAColor.attention)
        case .idle:
            EmptyView()
        }
    }
}

/// Unified-diff rendering with per-line color; the text carries the +/- sign,
/// so color is never the only signal.
struct DiffText: View {
    let diff: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.callout.monospaced())
                        .foregroundStyle(color(for: line))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 1)
                        .background(background(for: line))
                }
            }
            .padding(.vertical, 8)
            .textSelection(.enabled)
        }
        .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(OMAColor.separator) }
        .transaction { $0.animation = nil }
    }

    private func color(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .primary }
        if line.hasPrefix("+") { return OMAColor.positive }
        if line.hasPrefix("-") { return OMAColor.negative }
        if line.hasPrefix("@@") { return OMAColor.accent }
        return .secondary
    }

    private func background(for line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return OMAColor.positive.opacity(0.08) }
        if line.hasPrefix("-") { return OMAColor.negative.opacity(0.08) }
        return .clear
    }
}
