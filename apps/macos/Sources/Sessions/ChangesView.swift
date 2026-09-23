import SwiftUI

/// Structured changed files plus the raw diffstat. Changing content is never animated.
struct ChangesView: View {
    let status: SessionStatusDTO?
    let isLoading: Bool
    let notice: String?
    var projectID: String? = nil
    var session: SessionViewDTO? = nil
    var onSelectFile: ((FileDiffTarget) -> Void)? = nil
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let notice {
                    InlineNotice(notice, actionTitle: "Retry", action: onRefresh)
                }
                if let status {
                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeader("Changed files", symbol: "doc.badge.ellipsis") {
                            Text("\(status.changedFiles.count)")
                                .font(.subheadline.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        if status.changedFiles.isEmpty {
                            Text("No outstanding changes in the worktree.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(status.changedFiles) { file in
                                ChangedFileRow(file: file) {
                                    if let projectID, let onSelectFile {
                                        onSelectFile(FileDiffTarget(
                                            projectID: projectID,
                                            sessionID: session?.id,
                                            sessionTitle: session?.session.displayTitle,
                                            file: file
                                        ))
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .omaCard()

                    VStack(alignment: .leading, spacing: 12) {
                        PanelHeader("Diffstat", symbol: "chart.bar.doc.horizontal")
                        Text(status.diffStat.isEmpty ? "No diff." : status.diffStat)
                            .font(.callout.monospaced())
                            .foregroundStyle(status.diffStat.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(20)
                    .omaCard()
                } else if isLoading {
                    ProgressView("Loading changes…")
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    ContentUnavailableView("No status yet", systemImage: "doc.badge.ellipsis",
                                           description: Text("Refresh to fetch the worktree status."))
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
        }
        .transaction { $0.animation = nil }
    }
}
