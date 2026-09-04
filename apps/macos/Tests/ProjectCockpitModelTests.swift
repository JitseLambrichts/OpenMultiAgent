import Foundation
import Testing
@testable import OpenMultiAgent

@MainActor
struct ProjectCockpitModelTests {
    @Test func loadSeparatesActiveAndRecentSessions() async {
        let active = SessionViewDTO.sample(id: "active", status: "active")
        let ended = SessionViewDTO.sample(id: "ended", status: "ended")
        let client = CockpitClientStub(detail: ProjectDetailDTO(project: .cockpitSample, sessions: [ended, active]))
        let model = ProjectCockpitModel(project: .cockpitSample, client: client)

        await model.load()

        #expect(model.activeSessions.map(\.id) == ["active"])
        #expect(model.recentSessions.map(\.id) == ["ended"])
    }

    @Test func createsWorktreeSessionAndSelectsIt() async {
        let created = SessionViewDTO.sample(id: "created", status: "active")
        let client = CockpitClientStub(detail: ProjectDetailDTO(project: .cockpitSample, sessions: []), created: created)
        let model = ProjectCockpitModel(project: .cockpitSample, client: client)

        await model.create(NewSessionRequest(repoPath: "/repo", agent: .claude, usesWorktree: true, title: "M4", prompt: nil))

        #expect(model.selectedSessionID == "created")
        #expect(model.activeSessions.map(\.id) == ["created"])
        #expect(await client.lastCreateRequest == NewSessionRequest(
            repoPath: "/repo", agent: .claude, usesWorktree: true, title: "M4", prompt: nil
        ))
    }

    @Test func loadsDecisionsDocsAndChangedFilesForActiveSessions() async {
        let active = SessionViewDTO.sample(id: "active", status: "active")
        let client = CockpitClientStub(
            detail: ProjectDetailDTO(project: .cockpitSample, sessions: [active]),
            memories: [.sample(kind: .invariant, id: "m-inv"), .sample(kind: .decision, id: "m-dec")],
            docs: [LivingDocDTO(kind: .decision, path: ".oma/docs/decisions.md", title: "Decisions", modifiedAt: Date(timeIntervalSince1970: 9))],
            statuses: ["active": .sample(for: active, files: [ChangedFileDTO(path: "README.md", status: "M")])]
        )
        let model = ProjectCockpitModel(project: .cockpitSample, client: client)

        await model.load()

        #expect(model.recentDecisions.map(\.id) == ["m-dec", "m-inv"])
        #expect(model.docs.map(\.title) == ["Decisions"])
        #expect(model.changedFileCount == 1)
        #expect(model.changes.first?.session.id == "active")
    }

    @Test func failedRefreshKeepsStaleSessionsVisible() async {
        let active = SessionViewDTO.sample(id: "active", status: "active")
        let client = CockpitClientStub(detail: ProjectDetailDTO(project: .cockpitSample, sessions: [active]))
        let model = ProjectCockpitModel(project: .cockpitSample, client: client)
        await model.load()
        await client.fail(with: SidecarClientError.disconnected("Exitcode 1."))

        await model.load()

        #expect(model.sessions.map(\.id) == ["active"])
        #expect(model.notice?.action == .retry)
    }

    @Test func endingAnActiveSessionAsksForConfirmationFirst() async {
        let active = SessionViewDTO.sample(id: "active", status: "active")
        let client = CockpitClientStub(detail: ProjectDetailDTO(project: .cockpitSample, sessions: [active]))
        let model = ProjectCockpitModel(project: .cockpitSample, client: client)
        await model.load()

        model.requestEnd(sessionID: "active")

        #expect(model.alert?.primaryAction == .endSession)
        #expect(await client.endedSessionIDs.isEmpty)

        await model.perform(.endSession, for: "active")

        #expect(model.alert == nil)
        #expect(await client.endedSessionIDs == ["active"])
    }

    @Test func removeRequestRetainsCoreDirtyWorktreeError() async {
        let ended = SessionViewDTO.sample(id: "ended", status: "ended")
        let client = CockpitClientStub(
            detail: ProjectDetailDTO(project: .cockpitSample, sessions: [ended]),
            removeError: RPCErrorDTO(code: -32003, message: "The worktree has uncommitted changes", recovery: "keep_worktree_or_force")
        )
        let model = ProjectCockpitModel(project: .cockpitSample, client: client)
        await model.load()

        await model.remove(sessionID: "ended", force: false, keepWorktree: false)

        #expect(model.alert?.primaryAction == .keepWorktreeAndRetry)
        #expect(model.alert?.secondaryAction == .forceRemove)
        #expect(model.sessions.map(\.id) == ["ended"])

        await client.clearRemoveError()
        await model.perform(.keepWorktreeAndRetry, for: "ended")

        #expect(await client.removeCalls.last?.keepWorktree == true)
        #expect(model.sessions.isEmpty)
    }
}

private actor CockpitClientStub: DesktopAPI {
    struct RemoveCall: Equatable { let id: String; let force: Bool; let keepWorktree: Bool }

    let detail: ProjectDetailDTO
    let created: SessionViewDTO?
    let memories: [MemoryDTO]
    let docs: [LivingDocDTO]
    let statuses: [String: SessionStatusDTO]
    var removeError: RPCErrorDTO?
    var failure: (any Error)?
    var lastCreateRequest: NewSessionRequest?
    var endedSessionIDs: [String] = []
    var removeCalls: [RemoveCall] = []

    init(
        detail: ProjectDetailDTO,
        created: SessionViewDTO? = nil,
        memories: [MemoryDTO] = [],
        docs: [LivingDocDTO] = [],
        statuses: [String: SessionStatusDTO] = [:],
        removeError: RPCErrorDTO? = nil
    ) {
        self.detail = detail
        self.created = created
        self.memories = memories
        self.docs = docs
        self.statuses = statuses
        self.removeError = removeError
    }

    func fail(with error: any Error) { failure = error }
    func clearRemoveError() { removeError = nil }

    func hello() async throws -> HelloDTO { HelloDTO(protocolVersion: 1, appVersion: "test", agents: []) }
    func health() async throws -> HealthDTO { HealthDTO(ok: true, tmuxAvailable: true) }
    func listProjects() async throws -> [ProjectDTO] { [detail.project] }
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO { detail.project }
    func removeProject(id: String) async throws {}
    func projectDetail(id: String) async throws -> ProjectDetailDTO {
        if let failure { throw failure }
        return detail
    }
    func listMemory(repoPath: String?, limit: Int) async throws -> [MemoryDTO] { memories }
    func listDocs(repoPath: String) async throws -> [LivingDocDTO] { docs }
    func sessionStatus(id: String) async throws -> SessionStatusDTO {
        guard let status = statuses[id] else { throw SidecarClientError.unavailable("no status") }
        return status
    }
    func createSession(_ request: NewSessionRequest) async throws -> SessionViewDTO {
        lastCreateRequest = request
        return try #require(created)
    }
    func endSession(id: String) async throws { endedSessionIDs.append(id) }
    func removeSession(id: String, force: Bool, keepWorktree: Bool) async throws {
        removeCalls.append(RemoveCall(id: id, force: force, keepWorktree: keepWorktree))
        if let removeError { throw removeError }
    }
}

extension ProjectDTO {
    static let cockpitSample = ProjectDTO(
        id: "project-1",
        repoPath: "/repo",
        displayName: "Calm Command Center",
        createdAt: Date(timeIntervalSince1970: 1),
        lastOpenedAt: Date(timeIntervalSince1970: 2)
    )
}

extension SessionViewDTO {
    static func sample(id: String, status: String, worktree: String = "/repo/.worktrees/m4") -> SessionViewDTO {
        SessionViewDTO(
            session: SessionDTO(
                id: id,
                repoPath: "/repo",
                worktreePath: worktree,
                branch: "oma/m4",
                title: "Build M4",
                status: status,
                startedAt: Date(timeIntervalSince1970: 3),
                endedAt: status == "ended" ? Date(timeIntervalSince1970: 4) : nil
            ),
            runs: [],
            tmuxAlive: status == "active"
        )
    }
}

extension SessionStatusDTO {
    static func sample(for view: SessionViewDTO, files: [ChangedFileDTO]) -> SessionStatusDTO {
        SessionStatusDTO(session: view.session, runs: view.runs, tmuxAlive: view.tmuxAlive,
                         changedFiles: files, diffStat: " README.md | 1 +", pane: "")
    }
}

extension MemoryDTO {
    static func sample(kind: MemoryKind, id: String) -> MemoryDTO {
        MemoryDTO(id: id, kind: kind, scope: "repo", repoPath: "/repo", title: "Title \(id)", body: "Body",
                  confidence: 0.9, sourceSessionID: nil, createdAt: Date(timeIntervalSince1970: 5), supersededBy: nil)
    }
}
