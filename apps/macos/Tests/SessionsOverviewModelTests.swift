import Foundation
import Testing
@testable import OpenMultiAgent

@MainActor
struct SessionsOverviewModelTests {
    @Test func loadSeparatesActiveAndRecentSessions() async {
        let active = SessionViewDTO.sample(id: "active", status: "active")
        let ended = SessionViewDTO.sample(id: "ended", status: "ended")
        let client = OverviewClientStub(sessions: [ended, active])
        let model = SessionsOverviewModel(client: client)

        await model.load()

        #expect(model.active.map(\.id) == ["active"])
        #expect(model.recent.map(\.id) == ["ended"])
    }

    @Test func removeDropsTheSessionFromTheList() async {
        let ended = SessionViewDTO.sample(id: "ended", status: "ended")
        let client = OverviewClientStub(sessions: [ended])
        let model = SessionsOverviewModel(client: client)
        await model.load()

        model.requestRemove(sessionID: "ended")
        #expect(model.alert?.primaryAction == .removeSession)
        #expect(await client.removeCalls.isEmpty)

        await model.perform(.removeSession, for: "ended")

        #expect(model.alert == nil)
        #expect(model.sessions.isEmpty)
        #expect(await client.removeCalls.last == OverviewClientStub.RemoveCall(id: "ended", force: false, keepWorktree: false))
    }

    @Test func dirtyWorktreeKeepsTheSessionUntilTheCallerChooses() async {
        let ended = SessionViewDTO.sample(id: "ended", status: "ended")
        let client = OverviewClientStub(
            sessions: [ended],
            removeError: RPCErrorDTO(code: -32003, message: "The worktree has uncommitted changes", recovery: "keep_worktree_or_force")
        )
        let model = SessionsOverviewModel(client: client)
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

private actor OverviewClientStub: DesktopAPI {
    struct RemoveCall: Equatable { let id: String; let force: Bool; let keepWorktree: Bool }

    let sessions: [SessionViewDTO]
    var removeError: RPCErrorDTO?
    var removeCalls: [RemoveCall] = []

    init(sessions: [SessionViewDTO], removeError: RPCErrorDTO? = nil) {
        self.sessions = sessions
        self.removeError = removeError
    }

    func clearRemoveError() { removeError = nil }

    func hello() async throws -> HelloDTO { HelloDTO(protocolVersion: 1, appVersion: "test", agents: []) }
    func health() async throws -> HealthDTO { HealthDTO(ok: true, tmuxAvailable: true) }
    func listProjects() async throws -> [ProjectDTO] { [] }
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO {
        throw SidecarClientError.unavailable("unused")
    }
    func removeProject(id: String) async throws {}
    func listSessions(repoPath: String?, status: String?) async throws -> [SessionViewDTO] { sessions }
    func removeSession(id: String, force: Bool, keepWorktree: Bool) async throws {
        removeCalls.append(RemoveCall(id: id, force: force, keepWorktree: keepWorktree))
        if let removeError { throw removeError }
    }
}
