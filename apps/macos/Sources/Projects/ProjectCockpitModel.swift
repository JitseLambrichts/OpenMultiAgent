import Foundation
import Observation

enum CockpitAlertAction: Equatable, Sendable {
    case endSession
    case removeSession
    case keepWorktreeAndRetry
    case forceRemove
}

struct CockpitAlert: Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let title: String
    let message: String
    let primaryAction: CockpitAlertAction
    let secondaryAction: CockpitAlertAction?
    let isDestructive: Bool
}

/// Changed files of one active session, for the cockpit panel.
struct SessionChanges: Equatable, Identifiable, Sendable {
    var id: String { session.id }
    let session: SessionViewDTO
    let files: [ChangedFileDTO]
    let diffStat: String
}

@MainActor
@Observable
final class ProjectCockpitModel {
    let project: ProjectDTO
    @ObservationIgnored let client: any DesktopAPI

    private(set) var sessions: [SessionViewDTO] = []
    private(set) var memories: [MemoryDTO] = []
    private(set) var docs: [LivingDocDTO] = []
    private(set) var statuses: [String: SessionStatusDTO] = [:]
    private(set) var isLoading = false
    private(set) var isCreating = false
    private(set) var busySessionIDs: Set<String> = []
    private(set) var notice: ProjectsNotice?
    private(set) var alert: CockpitAlert?
    var selectedSessionID: String?
    var switchTarget: SessionViewDTO?

    init(project: ProjectDTO, client: any DesktopAPI) {
        self.project = project
        self.client = client
    }

    // MARK: Derived state

    var activeSessions: [SessionViewDTO] {
        sessions.filter { $0.session.isActive }
            .sorted { $0.session.startedAt > $1.session.startedAt }
    }

    var recentSessions: [SessionViewDTO] {
        sessions.filter { !$0.session.isActive }
            .sorted { $0.session.startedAt > $1.session.startedAt }
    }

    var recentDecisions: [MemoryDTO] {
        memories.filter { $0.kind == .decision } + memories.filter { $0.kind != .decision }
    }

    var changes: [SessionChanges] {
        activeSessions.compactMap { view in
            guard let status = statuses[view.id], !status.changedFiles.isEmpty else { return nil }
            return SessionChanges(session: view, files: status.changedFiles, diffStat: status.diffStat)
        }
    }

    var changedFileCount: Int {
        changes.reduce(0) { $0 + $1.files.count }
    }

    var branches: [String] {
        Array(Set(activeSessions.compactMap(\.session.branch))).sorted()
    }

    var selectedSession: SessionViewDTO? {
        sessions.first { $0.id == selectedSessionID }
    }

    func session(withID id: String) -> SessionViewDTO? {
        sessions.first { $0.id == id }
    }

    // MARK: Loading

    /// Loads sessions and lightweight summaries concurrently, then detailed
    /// status only for active sessions. Stale content stays visible on errors.
    func load() async {
        isLoading = true
        defer { isLoading = false }
        async let detail = client.projectDetail(id: project.id)
        async let memory = client.listMemory(repoPath: project.repoPath, limit: 8)
        async let docs = client.listDocs(repoPath: project.repoPath)

        do {
            sessions = try await detail.sessions
            notice = nil
        } catch {
            notice = ProjectsNotice(message: message(for: error), action: .retry)
        }
        if let loaded = try? await memory { memories = loaded }
        if let loaded = try? await docs { self.docs = loaded }
        await loadStatuses()
    }

    private func loadStatuses() async {
        let targets = activeSessions.prefix(TerminalWorkspaceModel.maximumCells)
        let client = self.client
        let loaded = await withTaskGroup(of: (String, SessionStatusDTO?).self) { group in
            for view in targets {
                group.addTask { (view.id, try? await client.sessionStatus(id: view.id)) }
            }
            var result: [String: SessionStatusDTO] = [:]
            for await (id, status) in group {
                if let status { result[id] = status }
            }
            return result
        }
        statuses = loaded
    }

    // MARK: Session lifecycle

    func create(_ request: NewSessionRequest) async {
        guard !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        do {
            let view = try await client.createSession(request)
            upsert(view)
            selectedSessionID = view.id
            notice = nil
        } catch {
            notice = ProjectsNotice(message: message(for: error), action: .retry)
        }
    }

    func resume(sessionID: String) async {
        await perform(sessionID: sessionID) {
            let view = try await self.client.resumeSession(id: sessionID)
            self.upsert(view)
            self.selectedSessionID = view.id
        }
    }

    func switchAgent(sessionID: String, agent: AgentKind, prompt: String?) async {
        await perform(sessionID: sessionID) {
            let view = try await self.client.switchSession(id: sessionID, agent: agent, prompt: prompt)
            self.upsert(view)
        }
    }

    /// Ending an active session asks first; an already-ended session is a no-op.
    func requestEnd(sessionID: String) {
        guard let view = session(withID: sessionID), view.session.isActive else { return }
        alert = CockpitAlert(
            id: "end-\(sessionID)",
            sessionID: sessionID,
            title: "Sessie “\(view.session.displayTitle)” beëindigen?",
            message: "De tmux-sessie stopt en de agent wordt afgesloten. Het transcript, de worktree en het geheugen blijven bewaard.",
            primaryAction: .endSession,
            secondaryAction: nil,
            isDestructive: true
        )
    }

    func end(sessionID: String) async {
        await perform(sessionID: sessionID) {
            try await self.client.endSession(id: sessionID)
            self.statuses.removeValue(forKey: sessionID)
            await self.load()
        }
    }

    /// Removal states whether the worktree will be retained before anything happens.
    func requestRemove(sessionID: String) {
        guard let view = session(withID: sessionID) else { return }
        let retains = !view.session.usesWorktree
        alert = CockpitAlert(
            id: "remove-\(sessionID)",
            sessionID: sessionID,
            title: "Sessie “\(view.session.displayTitle)” verwijderen?",
            message: retains
                ? "Het sessierecord verdwijnt uit OpenMultiAgent. De repository zelf wordt niet aangeraakt."
                : "Het sessierecord en de worktree \(view.session.worktreePath ?? "") worden verwijderd. Een worktree met niet-gecommitte wijzigingen blijft beschermd.",
            primaryAction: .removeSession,
            secondaryAction: nil,
            isDestructive: true
        )
    }

    func remove(sessionID: String, force: Bool, keepWorktree: Bool) async {
        busySessionIDs.insert(sessionID)
        defer { busySessionIDs.remove(sessionID) }
        do {
            try await client.removeSession(id: sessionID, force: force, keepWorktree: keepWorktree)
            sessions.removeAll { $0.id == sessionID }
            statuses.removeValue(forKey: sessionID)
            if selectedSessionID == sessionID { selectedSessionID = nil }
            notice = nil
        } catch let error as RPCErrorDTO where error.recoveryAction == .keepWorktreeOrForce {
            alert = CockpitAlert(
                id: "dirty-\(sessionID)",
                sessionID: sessionID,
                title: "De worktree bevat niet-gecommitte wijzigingen",
                message: "OpenMultiAgent verwijdert geen worktree met openstaand werk. Behoud de worktree en verwijder alleen de sessie, of forceer verwijdering en verlies de wijzigingen.",
                primaryAction: .keepWorktreeAndRetry,
                secondaryAction: .forceRemove,
                isDestructive: true
            )
        } catch {
            notice = ProjectsNotice(message: message(for: error), action: .retry)
        }
    }

    func perform(_ action: CockpitAlertAction, for sessionID: String) async {
        alert = nil
        switch action {
        case .endSession:
            await end(sessionID: sessionID)
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

    // MARK: Helpers

    private func perform(sessionID: String, _ work: () async throws -> Void) async {
        busySessionIDs.insert(sessionID)
        defer { busySessionIDs.remove(sessionID) }
        do {
            try await work()
            notice = nil
        } catch {
            notice = ProjectsNotice(message: message(for: error), action: .retry)
        }
    }

    private func upsert(_ view: SessionViewDTO) {
        sessions.removeAll { $0.id == view.id }
        sessions.insert(view, at: 0)
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ??
        "De projectcockpit kon niet worden bijgewerkt."
    }
}
