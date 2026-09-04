import Foundation
import Observation

enum ProjectsViewState: Equatable, Sendable {
    case idle
    case loading
    case empty
    case content
    case failed
}

enum ProjectsNoticeAction: Equatable, Sendable {
    case retry
    case chooseAnotherFolder
}

struct ProjectsNotice: Equatable, Sendable {
    let message: String
    let action: ProjectsNoticeAction
}

@MainActor
@Observable
final class ProjectsModel {
    @ObservationIgnored var client: any DesktopAPI

    private(set) var projects: [ProjectDTO] = []
    private(set) var state: ProjectsViewState = .idle
    private(set) var notice: ProjectsNotice?
    var searchQuery = ""

    var filteredProjects: [ProjectDTO] {
        guard !searchQuery.isEmpty else { return projects }
        return projects.filter {
            $0.displayName.localizedStandardContains(searchQuery) ||
            $0.repoPath.localizedStandardContains(searchQuery)
        }
    }

    init(client: any DesktopAPI) {
        self.client = client
    }

    func project(forRepoPath repoPath: String) -> ProjectDTO? {
        projects.first { $0.repoPath == repoPath }
    }

    func load() async {
        if projects.isEmpty { state = .loading }
        do {
            let loaded = try await client.listProjects()
            projects = loaded.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
            state = projects.isEmpty ? .empty : .content
            notice = nil
        } catch {
            state = projects.isEmpty ? .failed : .content
            notice = ProjectsNotice(
                message: userMessage(for: error),
                action: .retry
            )
        }
    }

    func addProject(url: URL) async {
        do {
            let project = try await client.addProject(
                repoPath: url.path(percentEncoded: false),
                displayName: nil
            )
            projects.removeAll { $0.id == project.id }
            projects.insert(project, at: 0)
            state = .content
            notice = nil
        } catch {
            notice = ProjectsNotice(
                message: userMessage(for: error),
                action: .chooseAnotherFolder
            )
            if projects.isEmpty { state = .failed }
        }
    }

    func removeProject(id: String) async {
        do {
            try await client.removeProject(id: id)
            projects.removeAll { $0.id == id }
            state = projects.isEmpty ? .empty : .content
            notice = nil
        } catch {
            notice = ProjectsNotice(
                message: userMessage(for: error),
                action: .retry
            )
        }
    }

    private func userMessage(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ??
        "OpenMultiAgent kon de projecten niet bijwerken."
    }
}
