import SwiftUI

/// Cross-project session overview. Opening a session jumps to its project.
struct SessionsOverviewView: View {
    let model: AppModel
    @State private var sessions: [SessionViewDTO] = []
    @State private var notice: String?
    @State private var isLoading = false

    private var active: [SessionViewDTO] {
        sessions.filter { $0.session.isActive }.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    private var recent: [SessionViewDTO] {
        sessions.filter { !$0.session.isActive }.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sessies")
                            .font(.largeTitle.weight(.semibold))
                        Text("Alle agentsessies over je projecten heen.")
                            .foregroundStyle(.secondary)
                    }
                    if let notice {
                        InlineNotice(notice, actionTitle: "Opnieuw") { Task { await load() } }
                    }
                    section("Actief", symbol: "bolt.fill", sessions: active,
                            empty: "Geen actieve sessies. Start er een met ⌘N.")
                    section("Recent", symbol: "clock", sessions: recent,
                            empty: "Afgeronde sessies verschijnen hier.")
                }
                .padding(28)
            }
        }
        .navigationTitle("Sessies")
        .toolbar {
            ToolbarItem {
                Button("Vernieuw", systemImage: "arrow.clockwise") { Task { await load() } }
                    .help("Vernieuw sessies")
                    .symbolEffect(.rotate, isActive: isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Nieuwe sessie", systemImage: "plus") { model.request(.newSession) }
                    .help("Start een nieuwe agentsessie (⌘N)")
                    .buttonStyle(.borderedProminent)
                    .tint(OMAColor.accent)
            }
        }
        .task { await load() }
        .onChange(of: model.reconciliationTick) { _, _ in Task { await load() } }
    }

    private func section(_ title: String, symbol: String, sessions: [SessionViewDTO], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title, symbol: symbol) {
                Text("\(sessions.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            if sessions.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(.horizontal, 16)
                    .omaCard()
            } else {
                ForEach(sessions) { view in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.projects.project(forRepoPath: view.session.repoPath)?.displayName ?? view.session.repoPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        SessionRow(view: view) { model.openSession(view) }
                    }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await model.client.listSessions(repoPath: nil, status: nil)
            notice = nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
