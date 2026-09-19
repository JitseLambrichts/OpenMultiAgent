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
        HStack(spacing: 0) {
            SidebarView(
                selection: sidebarSelection,
                isCollapsed: sidebarCollapsed,
                pendingPromotionCount: model.pendingPromotionCount
            )
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .omaPanelAnimation(model.selection, reduceMotion: reduceMotion)
        }
        .background(OMAColor.canvas)
        .ignoresSafeArea()
        .tint(OMAColor.accent)
        .task {
            await model.connect()
            model.startPendingPromotionCountLoop()
        }
        .onChange(of: model.reconciliationTick) { _, _ in
            Task { await model.refreshPendingPromotionCount() }
        }
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
                projects: sessionSheetProjects,
                preselected: sessionSheetPreselected,
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

    private var sidebarSelection: Binding<SidebarDestination> {
        Binding(
            get: { model.selection },
            set: { model.selection = $0 }
        )
    }

    private var sidebarCollapsed: Binding<Bool> {
        Binding(
            get: { windowState.isSidebarCollapsed },
            set: { windowState.isSidebarCollapsed = $0 }
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
            case .settings:
                AppSettingsView(app: model)
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

    /// Projectcontext voor de sessie-sheet: zit de gebruiker binnen een
    /// project (cockpit of sessie-workspace), dan is dat het enige project
    /// dat de sheet aanbiedt, zodat er geen projectkiezer verschijnt en de
    /// sessie altijd in het huidige project wordt aangemaakt. Daarbuiten
    /// (dashboard, Sessies, Geheugen, Docs, Instellingen) blijven alle
    /// projecten kiesbaar.
    private var currentProjectContext: ProjectDTO? {
        if let selected = model.selectedProject {
            if let fresh = model.projects.projects.first(where: { $0.id == selected.id }) {
                return fresh
            }
            return selected
        }
        if let session = model.selectedSession {
            return model.projects.project(forRepoPath: session.session.repoPath)
        }
        return nil
    }

    private var isInsideProject: Bool {
        model.selection == .projects && currentProjectContext != nil
    }

    private var sessionSheetProjects: [ProjectDTO] {
        if isInsideProject, let current = currentProjectContext {
            return [current]
        }
        return model.projects.projects
    }

    private var sessionSheetPreselected: ProjectDTO? {
        if isInsideProject {
            return currentProjectContext
        }
        return model.selectedProject
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

/// Custom navigation column: wordmark, a small "Navigatie" caption and one
/// row per destination. The selected row is a lime disc plus a soft pill.
/// Collapsible: when `isCollapsed` is true only the icons remain visible.
struct SidebarView: View {
    @Binding var selection: SidebarDestination
    @Binding var isCollapsed: Bool
    let pendingPromotionCount: Int

    var body: some View {
        VStack(alignment: isCollapsed ? .center : .leading, spacing: 0) {
            wordmark
                .padding(.top, 44)
                .padding(.bottom, 32)

            if !isCollapsed {
                Text("Navigatie")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
                    .padding(.bottom, 10)
            }

            VStack(spacing: 4) {
                ForEach(SidebarDestination.primaryDestinations) { destination in
                    row(destination)
                }
            }
            Spacer(minLength: 0)
            VStack(spacing: 4) {
                row(.settings)
                collapseToggle
            }
            .padding(.bottom, 12)
        }
        .padding(.horizontal, isCollapsed ? 8 : 20)
        .frame(width: isCollapsed ? 68 : 228)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(OMAColor.canvas)
        .animation(.easeInOut(duration: 0.18), value: isCollapsed)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Navigatie")
    }

    private var wordmark: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(OMAColor.accent)
                .accessibilityHidden(true)
            if !isCollapsed {
                Text("OpenMultiAgent")
                    .font(.system(size: 19, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.leading, isCollapsed ? 0 : 6)
    }

    private var collapseToggle: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            if isCollapsed {
                Image(systemName: "sidebar.right")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.secondary)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            } else {
                HStack(spacing: 12) {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                        .frame(width: 40, height: 40)
                    Text("Inklappen")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 4)
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(isCollapsed ? "Navigatie uitklappen" : "Navigatie inklappen")
        .accessibilityLabel(isCollapsed ? "Navigatie uitklappen" : "Navigatie inklappen")
        .keyboardShortcut("s", modifiers: [.command, .option])
    }

    private func row(_ destination: SidebarDestination) -> some View {
        let isSelected = destination == selection
        let badge = destination == .memory ? pendingPromotionCount : 0
        return Button {
            selection = destination
        } label: {
            if isCollapsed {
                icon(destination, isSelected: isSelected)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text("\(badge)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(OMAColor.onAccent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(OMAColor.attention, in: Capsule())
                                .offset(x: 6, y: -6)
                                .accessibilityLabel("\(badge) te beoordelen")
                        }
                    }
            } else {
                HStack(spacing: 12) {
                    icon(destination, isSelected: isSelected)
                    Text(destination.title)
                        .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    Spacer(minLength: 0)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(OMAColor.onAccent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(OMAColor.attention, in: Capsule())
                            .padding(.trailing, 12)
                            .accessibilityLabel("\(badge) te beoordelen")
                    }
                }
                .padding(.trailing, 4)
                .background(isSelected ? OMAColor.surface : .clear, in: Capsule())
                .contentShape(Capsule())
            }
        }
        .buttonStyle(.plain)
        .help(destination.title)
        .accessibilityLabel(destination.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func icon(_ destination: SidebarDestination, isSelected: Bool) -> some View {
        Image(systemName: destination.symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isSelected ? OMAColor.onAccent : Color.secondary)
            .frame(width: 40, height: 40)
            .background(isSelected ? OMAColor.accent : .clear, in: Circle())
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
