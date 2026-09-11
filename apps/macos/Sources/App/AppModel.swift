import Foundation
import Observation

enum SidebarDestination: String, CaseIterable, Identifiable, Codable, Sendable {
    case projects
    case sessions
    case memory
    case docs

    var id: Self { self }

    var title: String {
        switch self {
        case .projects: "Projecten"
        case .sessions: "Sessies"
        case .memory: "Geheugen"
        case .docs: "Living Docs"
        }
    }

    var symbol: String {
        switch self {
        case .projects: "square.grid.2x2"
        case .sessions: "terminal"
        case .memory: "brain.head.profile"
        case .docs: "doc.text"
        }
    }
}

enum SidecarConnection: Equatable, Sendable {
    case connecting
    case ready(agents: [String], tmuxAvailable: Bool)
    case failed(detail: String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

/// Menu and keyboard commands are routed through the model so a single binding
/// exists per shortcut, regardless of which view is currently in front.
enum AppCommand: Equatable, Sendable {
    case newSession
    case addProject
    case search
    case terminalLayout(TerminalLayout)
}

/// Composition root. Owns the sidecar client, connection state, top-level
/// navigation, and cross-view commands. Feature models own their own async work.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored private(set) var client: any DesktopAPI
    @ObservationIgnored private(set) var configuration: SidecarConfiguration?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private let makeClient: (SidecarConfiguration) -> SidecarClient

    let projects: ProjectsModel

    private(set) var connection: SidecarConnection = .connecting
    private(set) var customAgents: [CustomAgentDTO] = []
    var selection: SidebarDestination = .projects
    var selectedProject: ProjectDTO?
    var selectedSession: SessionViewDTO?
    var isInspectorVisible = false
    private(set) var pendingCommand: AppCommand?
    /// Incremented after lifecycle changes and on wake; feature models reload
    /// when it changes so a missed notification cannot leave stale state.
    private(set) var reconciliationTick = 0
    private(set) var pendingPromotionCount = 0
    @ObservationIgnored private var pendingPromotionCountTask: Task<Void, Never>?
    @ObservationIgnored private let pendingPromotionCountInterval: Duration

    init(client: any DesktopAPI, pendingPromotionCountInterval: Duration = .seconds(60)) {
        self.client = client
        self.configuration = nil
        self.projects = ProjectsModel(client: client)
        self.makeClient = { SidecarClient(configuration: $0) }
        self.pendingPromotionCountInterval = pendingPromotionCountInterval
    }

    init(
        configuration: SidecarConfiguration = .resolve(),
        makeClient: @escaping (SidecarConfiguration) -> SidecarClient = { SidecarClient(configuration: $0) },
        pendingPromotionCountInterval: Duration = .seconds(60)
    ) {
        let sidecar = makeClient(configuration)
        self.client = sidecar
        self.configuration = configuration
        self.projects = ProjectsModel(client: sidecar)
        self.makeClient = makeClient
        self.pendingPromotionCountInterval = pendingPromotionCountInterval
        observe(sidecar)
    }

    // MARK: Connection

    func connect() async {
        connection = .connecting
        do {
            let hello = try await client.hello()
            // Health is advisory: a missing tmux is shown in the UI, it never
            // blocks browsing projects, memory, and docs.
            let health = (try? await client.health()) ?? HealthDTO(ok: false, tmuxAvailable: false)
            connection = .ready(agents: hello.agents, tmuxAvailable: health.tmuxAvailable)
            customAgents = (try? await client.listCustomAgents()) ?? []
            await projects.load()
        } catch {
            connection = .failed(detail: userMessage(for: error))
        }
    }

    var availableAgents: [AgentKind] {
        if case .ready(let agents, _) = connection, !agents.isEmpty {
            return agents.map { AgentKind(rawValue: $0) }
        }
        return AgentKind.allCases + customAgents.map { AgentKind(rawValue: $0.id) }
    }

    func displayName(for agent: AgentKind) -> String {
        customAgents.first { $0.id == agent.rawValue }?.name ?? agent.title
    }

    func symbol(for agent: AgentKind) -> String {
        agent.resolvedSymbol(in: customAgents)
    }

    func symbol(forAgentID id: String) -> String {
        symbol(for: AgentKind(rawValue: id))
    }

    func refreshCustomAgents() async {
        customAgents = (try? await client.listCustomAgents()) ?? []
        if let hello = try? await client.hello() {
            if case .ready(_, let tmuxAvailable) = connection {
                connection = .ready(agents: hello.agents, tmuxAvailable: tmuxAvailable)
            } else {
                connection = .ready(agents: hello.agents, tmuxAvailable: true)
            }
        }
    }

    /// Replaces the sidecar process (development only) and reconnects.
    func useCheckout(_ root: URL) async {
        let development = SidecarConfiguration.development
        let configuration = SidecarConfiguration(
            executableURL: development.executableURL,
            arguments: development.arguments,
            workspaceRoot: root,
            source: .development
        )
        rebuildClient(configuration)
        await connect()
    }

    func reconnect() async {
        if let configuration {
            rebuildClient(configuration)
        }
        await connect()
    }

    /// Asks the sidecar to exit. Bounded so a wedged sidecar never blocks quitting.
    func shutdownSidecar() async {
        guard let sidecar = client as? SidecarClient else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await sidecar.shutdown() }
            group.addTask { try? await Task.sleep(for: .seconds(2)) }
            await group.next()
            group.cancelAll()
        }
    }

    private func rebuildClient(_ configuration: SidecarConfiguration) {
        eventTask?.cancel()
        let sidecar = makeClient(configuration)
        self.configuration = configuration
        client = sidecar
        projects.client = sidecar
        observe(sidecar)
    }

    private func observe(_ sidecar: SidecarClient) {
        eventTask = Task { [weak self] in
            for await event in sidecar.events {
                guard let self else { return }
                switch event {
                case .disconnected(let detail):
                    // Terminal attachments stay usable; only sidecar-backed views
                    // switch to the recovery state.
                    connection = .failed(detail: detail)
                }
            }
        }
    }

    // MARK: Navigation

    func openProject(_ project: ProjectDTO) {
        selectedSession = nil
        selectedProject = project
        selection = .projects
    }

    func openSession(_ session: SessionViewDTO) {
        if selectedProject?.repoPath != session.session.repoPath {
            selectedProject = projects.project(forRepoPath: session.session.repoPath) ?? selectedProject
        }
        selectedSession = session
        selection = .projects
    }

    func closeSession() {
        selectedSession = nil
    }

    func closeProject() {
        selectedSession = nil
        selectedProject = nil
    }

    // MARK: Commands and reconciliation

    func request(_ command: AppCommand) {
        pendingCommand = command
    }

    /// Consumes the pending command if it matches, so exactly one view acts on it.
    @discardableResult
    func consume(_ command: AppCommand) -> Bool {
        guard pendingCommand == command else { return false }
        pendingCommand = nil
        return true
    }

    func consumeTerminalLayout() -> TerminalLayout? {
        guard case .terminalLayout(let layout) = pendingCommand else { return nil }
        pendingCommand = nil
        return layout
    }

    func reconcile() {
        reconciliationTick &+= 1
    }

    func startPendingPromotionCountLoop() {
        guard pendingPromotionCountTask == nil else { return }
        pendingPromotionCountTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshPendingPromotionCount()
            while !Task.isCancelled {
                try? await Task.sleep(for: self.pendingPromotionCountInterval)
                if Task.isCancelled { break }
                await self.refreshPendingPromotionCount()
            }
        }
    }

    func refreshPendingPromotionCount() async {
        if let result = try? await client.pendingPromotionCount() {
            pendingPromotionCount = result.count
        }
    }

    /// Creates a session from the root-level sheet and navigates to it.
    func createSession(_ request: NewSessionRequest) async throws {
        let created = try await client.createSession(request)
        reconcile()
        openSession(created)
    }

    private func userMessage(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
