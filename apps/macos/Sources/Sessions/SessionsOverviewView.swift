import SwiftUI

@MainActor
@Observable
final class SessionsOverviewModel {
    @ObservationIgnored let client: any DesktopAPI

    private(set) var sessions: [SessionViewDTO] = []
    private(set) var isLoading = false
    private(set) var notice: String?
    private(set) var busySessionIDs: Set<String> = []
    private(set) var alert: CockpitAlert?

    init(client: any DesktopAPI) {
        self.client = client
    }

    var active: [SessionViewDTO] {
        sessions.filter(\.session.isActive).sorted { $0.session.startedAt > $1.session.startedAt }
    }

    var recent: [SessionViewDTO] {
        sessions.filter { !$0.session.isActive }.sorted { $0.session.startedAt > $1.session.startedAt }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await client.listSessions(repoPath: nil, status: nil)
            notice = nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func requestRemove(sessionID: String) {
        guard let view = sessions.first(where: { $0.id == sessionID }) else { return }
        alert = .removeConfirmation(for: view)
    }

    func remove(sessionID: String, force: Bool, keepWorktree: Bool) async {
        busySessionIDs.insert(sessionID)
        defer { busySessionIDs.remove(sessionID) }
        do {
            try await client.removeSession(id: sessionID, force: force, keepWorktree: keepWorktree)
            sessions.removeAll { $0.id == sessionID }
            notice = nil
        } catch let error as RPCErrorDTO where error.recoveryAction == .keepWorktreeOrForce {
            alert = .dirtyWorktree(sessionID: sessionID)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func perform(_ action: CockpitAlertAction, for sessionID: String) async {
        alert = nil
        switch action {
        case .endSession:
            break
        case .removeSession:
            await remove(sessionID: sessionID, force: false, keepWorktree: false)
        case .keepWorktreeAndRetry:
            await remove(sessionID: sessionID, force: false, keepWorktree: true)
        case .forceRemove:
            await remove(sessionID: sessionID, force: true, keepWorktree: false)
        }
    }

    func dismissAlert() {
        alert = nil
    }
}

/// Cross-project session overview. Opening a session jumps to its project.
struct SessionsOverviewView: View {
    let app: AppModel
    @State private var model: SessionsOverviewModel

    init(app: AppModel) {
        self.app = app
        _model = State(initialValue: SessionsOverviewModel(client: app.client))
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
                    if let notice = model.notice {
                        InlineNotice(notice, actionTitle: "Opnieuw") { Task { await model.load() } }
                    }
                    section("Actief", symbol: "bolt.fill", sessions: model.active,
                            empty: "Geen actieve sessies. Start er een met ⌘N.")
                    section("Recent", symbol: "clock", sessions: model.recent,
                            empty: "Afgeronde sessies verschijnen hier.")
                }
                .padding(28)
            }
        }
        .navigationTitle("Sessies")
        .toolbar {
            ToolbarItem {
                Button("Vernieuw", systemImage: "arrow.clockwise") { Task { await model.load() } }
                    .help("Vernieuw sessies")
                    .symbolEffect(.rotate, isActive: model.isLoading)
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Nieuwe sessie", systemImage: "plus") { app.request(.newSession) }
                    .help("Start een nieuwe agentsessie (⌘N)")
                    .buttonStyle(.borderedProminent)
                    .tint(OMAColor.accent)
            }
        }
        .alert(item: Binding(get: { model.alert }, set: { if $0 == nil { model.dismissAlert() } })) { alert in
            sessionLifecycleAlert(alert) { action in
                Task { await model.perform(action, for: alert.sessionID) }
            }
        }
        .task { await model.load() }
        .onChange(of: app.reconciliationTick) { _, _ in Task { await model.load() } }
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
                        Text(app.projects.project(forRepoPath: view.session.repoPath)?.displayName ?? view.session.repoPath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                        SessionRow(view: view, actions: actions(for: view), agentSymbol: view.currentAgent.map { app.symbol(for: $0) })
                            .opacity(model.busySessionIDs.contains(view.id) ? 0.55 : 1)
                            .disabled(model.busySessionIDs.contains(view.id))
                    }
                }
            }
        }
    }

    private func actions(for view: SessionViewDTO) -> SessionRowActions {
        SessionRowActions(
            open: { app.openSession(view) },
            remove: { model.requestRemove(sessionID: view.id) }
        )
    }
}
