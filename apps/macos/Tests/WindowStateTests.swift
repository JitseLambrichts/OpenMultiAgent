import Foundation
import Testing
@testable import OpenMultiAgent

struct WindowStateTests {
    @Test func roundTripsThroughSceneStorageRawValue() throws {
        let state = WindowState(destination: .sessions, projectID: "p1", sessionID: "s1", isInspectorVisible: true, terminalLayout: .twoByTwo)

        let restored = try #require(WindowState(rawValue: state.rawValue))

        #expect(restored == state)
        #expect(WindowState(rawValue: "not json") == nil)
    }

    @Test func restorationNeverResolvesStaleOrForeignIdentifiers() {
        let project = ProjectDTO.cockpitSample
        let state = WindowState(destination: .projects, projectID: project.id, sessionID: "s1")
        let ownSession = SessionViewDTO.sample(id: "s1", status: "active")
        let foreign = SessionViewDTO(
            session: SessionDTO(id: "s1", repoPath: "/elsewhere", worktreePath: nil, branch: nil, title: nil,
                                status: "active", startedAt: Date(), endedAt: nil),
            runs: [], tmuxAlive: true
        )

        #expect(state.resolveProject(in: [project]) == project)
        #expect(state.resolveProject(in: []) == nil)
        #expect(state.resolveSession(in: [ownSession], project: project) == ownSession)
        #expect(state.resolveSession(in: [foreign], project: project) == nil)
        #expect(state.resolveSession(in: [ownSession], project: nil) == nil)
    }
}
