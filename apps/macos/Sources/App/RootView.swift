import AppKit
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @SceneStorage("window-state") private var windowState = WindowState()
    @State private var showsRootSessionSheet = false
    @State private var hasRestored = false
    @State private var rootNotice: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(SidebarDestination.allCases, selection: sidebarSelection) { destination in
                Label(destination.title, systemImage: destination.symbol)
                    .tag(destination)
            }
            .navigationTitle("OpenMultiAgent")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 260)
        } detail: {
            detail
                .omaPanelAnimation(model.selection, reduceMotion: reduceMotion)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(OMAColor.accent)
        .task { await model.connect() }
        .onChange(of: model.projects.projects) { _, projects in restoreIfNeeded(projects: projects) }
        .onChange(of: model.selection) { _, value in windowState.destination = value }
        .onChange(of: model.selectedProject) { _, value in windowState.projectID = value?.id }
        .onChange(of: model.selectedSession) { _, value in windowState.sessionID = value?.id }
        .onChange(of: model.isInspectorVisible) { _, value in windowState.isInspectorVisible = value }
        .onChange(of: model.pendingCommand) { _, _ in handlePendingCommand() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.reconcile() }
        }
        .sheet(isPresented: $showsRootSessionSheet) {
            NewSessionSheet(
                projects: model.projects.projects,
                preselected: model.selectedProject,
                agents: model.availableAgents,
                displayName: { model.displayName(for: $0) },
                symbol: { model.symbol(for: $0) }
            ) { request in
                do {
                    try await model.createSession(request)
                } catch {
                    rootNotice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
        }
        .alert("Sessie kon niet starten", isPresented: Binding(
            get: { rootNotice != nil },
            set: { if !$0 { rootNotice = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(rootNotice ?? "")
        }
    }

    private var sidebarSelection: Binding<SidebarDestination?> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 ?? .projects }
        )
    }

    @ViewBuilder
    private var detail: some View {
        if case .failed(let detail) = model.connection {
            RecoveryView(
                detail: detail,
                configuration: model.configuration,
                onReconnect: { Task { await model.reconnect() } },
                onChooseCheckout: { url in Task { await model.useCheckout(url) } }
            )
        } else {
            switch model.selection {
            case .projects:
                projectsColumn
            case .sessions:
                SessionsOverviewView(app: model)
            case .memory:
                MemorySearchView(
                    client: model.client,
                    scopeRepoPath: nil,
                    projects: model.projects.projects,
                    app: model
                )
            case .docs:
                LivingDocsView(model: model)
            }
        }
    }

    @ViewBuilder
    private var projectsColumn: some View {
        if let session = model.selectedSession {
            SessionWorkspaceView(session: session, app: model)
                .id(session.id)
        } else if let project = model.selectedProject {
            ProjectCockpitView(project: project, app: model)
                .id(project.id)
        } else {
            ProjectsDashboard(
                model: model.projects,
                onOpen: { model.openProject($0) },
                onNewSession: { project in
                    if let project { model.selectedProject = project }
                    showsRootSessionSheet = true
                }
            )
        }
    }

    private func handlePendingCommand() {
        switch model.pendingCommand {
        case .newSession:
            model.consume(.newSession)
            guard model.connection.isReady else { return }
            showsRootSessionSheet = true
        case .addProject:
            model.consume(.addProject)
            guard model.connection.isReady else { return }
            ProjectChooser.choose { url in
                Task { await model.projects.addProject(url: url) }
            }
        case .search:
            if model.selection != .memory {
                model.selection = .memory
            }
        case .terminalLayout, .none:
            break
        }
    }

    private func restoreIfNeeded(projects: [ProjectDTO]) {
        guard !hasRestored, !projects.isEmpty else { return }
        hasRestored = true
        model.selection = windowState.destination
        model.isInspectorVisible = windowState.isInspectorVisible
        if let project = windowState.resolveProject(in: projects) {
            model.selectedProject = project
            if let sessionID = windowState.sessionID {
                Task {
                    let sessions = (try? await model.client.listSessions(repoPath: project.repoPath, status: nil)) ?? []
                    if let session = windowState.resolveSession(in: sessions, project: project) {
                        model.selectedSession = session
                    }
                    _ = sessionID
                }
            }
        }
    }
}

/// One shared open panel so Command-O and the dashboard button behave the same.
enum ProjectChooser {
    @MainActor
    static func choose(_ completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Voeg een Git-project toe"
        panel.message = "Kies de map die de Git-repository bevat."
        panel.prompt = "Voeg toe"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        completion(url)
    }
}
