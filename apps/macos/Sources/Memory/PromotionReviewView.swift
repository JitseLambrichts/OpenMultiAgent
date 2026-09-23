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
            PageTitle(title: "Review Knowledge", subtitle: subtitle)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                statusLine
                Spacer()
                Button("Close", action: onClose)
                    .buttonStyle(.omaSecondary)
                    .keyboardShortcut(.cancelAction)
                switch state {
                case .preview:
                    Button("Apply", systemImage: "checkmark.seal", action: onApply)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.omaPrimary)
                case .failed:
                    Button("Try Again", systemImage: "arrow.clockwise", action: onRetry)
                        .buttonStyle(.omaPrimary)
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
        case .preview(_, let count): "\(count) candidate record(s) from “\(sessionTitle)”. Nothing is written until you apply."
        case .applying: "Writing knowledge…"
        case .applied(let files): "\(files.count) file(s) updated under .oma/docs."
        case .failed(let message, _): message
        case .extracting: "Extracting knowledge from the transcript…"
        case .idle: "No preview yet."
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
                Label("Promotion failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        case .idle:
            ContentUnavailableView("No preview", systemImage: "doc.text.magnifyingglass")
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state {
        case .applied:
            StatusBadge(text: "Applied", symbol: "checkmark.circle.fill", color: OMAColor.positive)
        case .applying, .extracting:
            StatusBadge(text: "Working", symbol: "progress.indicator", color: OMAColor.accent)
        case .failed:
            StatusBadge(text: "Failed", symbol: "xmark.octagon", color: OMAColor.negative)
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
        .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
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
