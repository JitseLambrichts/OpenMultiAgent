import SwiftUI

/// Sections shared by the cockpit inspector and the session workspace inspector.
struct SessionInspectorSections: View {
    let session: SessionViewDTO
    let status: SessionStatusDTO?
    var symbolForAgent: (String) -> String = { AgentKind(rawValue: $0).symbol }
    var onSelectFile: ((ChangedFileDTO) -> Void)? = nil

    var body: some View {
        Section("Session") {
            LabeledContent("Title", value: session.session.displayTitle)
            LabeledContent("Status", value: session.session.isActive ? "Active" : "Completed")
            LabeledContent("tmux", value: session.tmuxAlive ? "Running" : "Not running")
            if let branch = session.session.branch {
                LabeledContent("Branch") { Text(branch).font(.caption.monospaced()) }
            }
            LabeledContent("Started", value: session.session.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let endedAt = session.session.endedAt {
                LabeledContent("Ended", value: endedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        Section("Worktree") {
            LabeledContent("Isolated", value: session.session.usesWorktree ? "Yes" : "No, main checkout")
            LabeledContent("Path") {
                Text(session.session.worktreePath ?? session.session.repoPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        if let status {
            Section("Changes (\(status.changedFiles.count))") {
                if status.changedFiles.isEmpty {
                    Text("No outstanding changes.").foregroundStyle(.secondary)
                } else {
                    ForEach(status.changedFiles) { file in
                        ChangedFileRow(file: file) {
                            onSelectFile?(file)
                        }
                    }
                }
                if !status.diffStat.isEmpty {
                    Text(status.diffStat)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        Section("Agent runs (\(session.runs.count))") {
            if session.runs.isEmpty {
                Text("No runs yet.").foregroundStyle(.secondary)
            }
            ForEach(session.runs) { run in
                VStack(alignment: .leading, spacing: 3) {
                    Label(run.agent.capitalized, systemImage: symbolForAgent(run.agent))
                        .font(.body.weight(.medium))
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)
                         + (run.endedAt.map { " – \($0.formatted(date: .omitted, time: .shortened))" } ?? " – now"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let native = run.nativeSessionID {
                        Text(native).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct SessionInspector: View {
    let session: SessionViewDTO
    let status: SessionStatusDTO?
    var symbolForAgent: (String) -> String = { AgentKind(rawValue: $0).symbol }
    var onSelectFile: ((ChangedFileDTO) -> Void)? = nil

    var body: some View {
        List {
            SessionInspectorSections(session: session, status: status, symbolForAgent: symbolForAgent, onSelectFile: onSelectFile)
        }
        .scrollContentBackground(.hidden)
        .background(OMAColor.surface)
    }
}
