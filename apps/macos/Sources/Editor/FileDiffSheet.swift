import SwiftUI

struct FileDiffTarget: Identifiable, Equatable, Sendable {
    var id: String { "\(sessionID ?? "project"):\(file.path)" }
    let projectID: String
    let sessionID: String?
    let sessionTitle: String?
    let file: ChangedFileDTO
}

struct FileDiffSheet: View {
    let target: FileDiffTarget
    let client: any DesktopAPI
    let onOpenEditor: (FileDiffTarget) -> Void

    @State private var diff: String?
    @State private var notice: String?
    @State private var isLoading = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AccentDisc(symbol: "doc.badge.ellipsis", size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(target.file.path)
                        .font(.headline.monospaced())
                        .lineLimit(2)
                    if let sessionTitle = target.sessionTitle {
                        Text(sessionTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if let notice {
                InlineNotice(notice, actionTitle: "Opnieuw") { Task { await load() } }
            }
            ScrollView {
                if isLoading && diff == nil {
                    ProgressView("Diff laden…")
                        .frame(maxWidth: .infinity, minHeight: 160)
                } else {
                    Text((diff?.isEmpty == false) ? diff! : "Geen diff voor dit bestand.")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(minHeight: 180)
            .padding(14)
            .omaInnerCard()
            HStack {
                Button("Sluiten") { dismiss() }
                    .buttonStyle(.omaSecondary)
                Spacer()
                Button("Open in editor", systemImage: "chevron.right") {
                    onOpenEditor(target)
                    dismiss()
                }
                .buttonStyle(.omaPrimary)
            }
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 360)
        .background(OMAColor.canvas)
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.gitFileDiff(
                projectID: target.projectID,
                sessionID: target.sessionID,
                path: target.file.path
            )
            diff = result.diff
            notice = nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}