import Foundation
import Observation

enum CockpitAlertAction: Equatable, Sendable {
    case endSession
    case mergeAndEnd
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

    /// Removal states whether the worktree will be retained before anything happens.
    static func removeConfirmation(for view: SessionViewDTO) -> CockpitAlert {
        let retains = !view.session.usesWorktree
        return CockpitAlert(
            id: "remove-\(view.id)",
            sessionID: view.id,
            title: "Delete session “\(view.session.displayTitle)”?",
            message: retains
                ? "The session record is removed from OpenMultiAgent. The repository itself is left untouched."
                : "The session record and worktree \(view.session.worktreePath ?? "") will be deleted. A worktree with uncommitted changes stays protected.",
            primaryAction: .removeSession,
            secondaryAction: nil,
            isDestructive: true
        )
    }

    static func dirtyWorktree(sessionID: String) -> CockpitAlert {
        CockpitAlert(
            id: "dirty-\(sessionID)",
            sessionID: sessionID,
            title: "The worktree has uncommitted changes",
            message: "OpenMultiAgent will not delete a worktree with uncommitted work. Keep the worktree and remove only the session, or force deletion and lose the changes.",
            primaryAction: .keepWorktreeAndRetry,
            secondaryAction: .forceRemove,
            isDestructive: true
        )
    }

    /// Merge-then-end for worktree sessions: the primary action merges first.
    static func mergeEndConfirmation(for view: SessionViewDTO) -> CockpitAlert {
        CockpitAlert(
            id: "merge-end-\(view.id)",
            sessionID: view.id,
            title: "End session “\(view.session.displayTitle)”?",
            message: "This session uses its own worktree (\(view.session.branch ?? "unknown branch")). Merge & End merges the branch first, then removes the worktree. Uncommitted changes or conflicts keep the session active.",
            primaryAction: .mergeAndEnd,
            secondaryAction: .endSession,
            isDestructive: true
        )
    }
}

extension CockpitAlertAction {
    var title: String {
        switch self {
        case .endSession: "End"
        case .mergeAndEnd: "Merge & End"
        case .removeSession: "Delete"
        case .keepWorktreeAndRetry: "Keep Worktree"
        case .forceRemove: "Force Delete"
        }
    }
}

/// Localised end/merge failure surfaced through the cockpit notice.
struct CockpitEndError: LocalizedError, Equatable {
    let text: String
    var errorDescription: String? { text }
    static func message(_ text: String) -> CockpitEndError { CockpitEndError(text: text) }
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
    /// Merge/end errors (dirty worktree, conflicts) stay until a new end
    /// attempt succeeds or the user dismisses them. A background `load()`
    /// must not clear them, or it looks as if "the session was not updated"
    /// with no explanation.
    private(set) var endNotice: String?
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
    /// Worktree sessions offer merge-then-end as the primary action.
    func requestEnd(sessionID: String) {
        guard let view = session(withID: sessionID), view.session.isActive else { return }
        if view.session.usesWorktree {
            alert = .mergeEndConfirmation(for: view)
            return
        }
        alert = CockpitAlert(
            id: "end-\(sessionID)",
            sessionID: sessionID,
            title: "End session “\(view.session.displayTitle)”?",
            message: "The tmux session stops and the agent is shut down. The transcript, worktree, and memory are kept.",
            primaryAction: .endSession,
            secondaryAction: nil,
            isDestructive: true
        )
    }

    func end(sessionID: String, merge: Bool = false) async {
        busySessionIDs.insert(sessionID)
        defer { busySessionIDs.remove(sessionID) }
        do {
            try await client.endSession(id: sessionID, merge: merge)
        } catch let error as RPCErrorDTO {
            switch error.recoveryAction {
            case .commitFirst:
                endNotice = "The worktree has uncommitted changes. Commit first, then try merging again. The session stays active."
            case .resolveConflicts:
                endNotice = "The merge has conflicts. Resolve them in the worktree (the merge was aborted) and try again. The session stays active."
            default:
                notice = ProjectsNotice(message: message(for: error), action: .retry)
            }
            return
        } catch {
            notice = ProjectsNotice(message: message(for: error), action: .retry)
            return
        }
        endNotice = nil
        notice = nil
        statuses.removeValue(forKey: sessionID)
        await load()
    }

    func clearEndNotice() {
        endNotice = nil
    }

    func requestRemove(sessionID: String) {
        guard let view = session(withID: sessionID) else { return }
        alert = .removeConfirmation(for: view)
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
            alert = .dirtyWorktree(sessionID: sessionID)
        } catch {
            notice = ProjectsNotice(message: message(for: error), action: .retry)
        }
    }

    func perform(_ action: CockpitAlertAction, for sessionID: String) async {
        alert = nil
        switch action {
        case .endSession:
            await end(sessionID: sessionID, merge: false)
        case .mergeAndEnd:
            await end(sessionID: sessionID, merge: true)
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
        "The project cockpit could not be updated."
    }
}
