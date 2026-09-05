import SwiftUI

/// Sections shared by the cockpit inspector and the session workspace inspector.
struct SessionInspectorSections: View {
    let session: SessionViewDTO
    let status: SessionStatusDTO?
    var symbolForAgent: (String) -> String = { AgentKind(rawValue: $0).symbol }

    var body: some View {
        Section("Sessie") {
            LabeledContent("Titel", value: session.session.displayTitle)
            LabeledContent("Status", value: session.session.isActive ? "Actief" : "Afgerond")
            LabeledContent("tmux", value: session.tmuxAlive ? "Draait" : "Niet actief")
            if let branch = session.session.branch {
                LabeledContent("Branch") { Text(branch).font(.caption.monospaced()) }
            }
            LabeledContent("Gestart", value: session.session.startedAt.formatted(date: .abbreviated, time: .shortened))
            if let endedAt = session.session.endedAt {
                LabeledContent("Beëindigd", value: endedAt.formatted(date: .abbreviated, time: .shortened))
            }
        }
        Section("Worktree") {
            LabeledContent("Geïsoleerd", value: session.session.usesWorktree ? "Ja" : "Nee, hoofdcheckout")
            LabeledContent("Pad") {
                Text(session.session.worktreePath ?? session.session.repoPath)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
        if let status {
            Section("Wijzigingen (\(status.changedFiles.count))") {
                if status.changedFiles.isEmpty {
                    Text("Geen openstaande wijzigingen.").foregroundStyle(.secondary)
                } else {
                    ForEach(status.changedFiles) { file in
                        ChangedFileRow(file: file)
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
        Section("Agent-runs (\(session.runs.count))") {
            if session.runs.isEmpty {
                Text("Nog geen runs.").foregroundStyle(.secondary)
            }
            ForEach(session.runs) { run in
                VStack(alignment: .leading, spacing: 3) {
                    Label(run.agent.capitalized, systemImage: symbolForAgent(run.agent))
                        .font(.body.weight(.medium))
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened)
                         + (run.endedAt.map { " – \($0.formatted(date: .omitted, time: .shortened))" } ?? " – nu"))
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

    var body: some View {
        List {
            SessionInspectorSections(session: session, status: status, symbolForAgent: symbolForAgent)
        }
        .scrollContentBackground(.hidden)
        .background(OMAColor.canvas)
    }
}
