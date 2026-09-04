import Foundation
import Testing
@testable import OpenMultiAgent

@MainActor
struct ProjectsModelTests {
    @Test func initialLoadMovesFromLoadingToContent() async {
        let project = ProjectDTO.sample
        let model = ProjectsModel(client: ProjectsClientStub(projects: [project]))

        await model.load()

        #expect(model.state == .content)
        #expect(model.projects == [project])
        #expect(model.notice == nil)
    }

    @Test func failedRefreshKeepsExistingProjectsVisible() async {
        let project = ProjectDTO.sample
        let model = ProjectsModel(client: ProjectsClientStub(projects: [project]))
        await model.load()
        model.client = ProjectsClientStub(error: .unavailable("Offline"))

        await model.load()

        #expect(model.state == .content)
        #expect(model.projects == [project])
        #expect(model.notice?.action == .retry)
    }

    @Test func addingProjectUpdatesTheDashboard() async {
        let project = ProjectDTO.sample
        let client = ProjectsClientStub(projects: [], addedProject: project)
        let model = ProjectsModel(client: client)

        await model.addProject(url: URL(fileURLWithPath: project.repoPath))

        #expect(model.projects == [project])
        #expect(model.state == .content)
    }
}

private actor ProjectsClientStub: DesktopAPI {
    let projects: [ProjectDTO]
    let addedProject: ProjectDTO?
    let error: SidecarClientError?

    init(
        projects: [ProjectDTO] = [],
        addedProject: ProjectDTO? = nil,
        error: SidecarClientError? = nil
    ) {
        self.projects = projects
        self.addedProject = addedProject
        self.error = error
    }

    func hello() async throws -> HelloDTO {
        HelloDTO(protocolVersion: 1, appVersion: "test", agents: [])
    }

    func health() async throws -> HealthDTO {
        HealthDTO(ok: true, tmuxAvailable: true)
    }

    func listProjects() async throws -> [ProjectDTO] {
        if let error { throw error }
        return projects
    }

    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO {
        if let error { throw error }
        return try #require(addedProject)
    }

    func removeProject(id: String) async throws {
        if let error { throw error }
    }
}

private extension ProjectDTO {
    static let sample = ProjectDTO(
        id: "project-1",
        repoPath: "/Users/example/OpenMultiAgent",
        displayName: "OpenMultiAgent",
        createdAt: Date(timeIntervalSince1970: 1),
        lastOpenedAt: Date(timeIntervalSince1970: 2)
    )
}
