import Foundation

/// Per-window restoration state. Stored as one JSON string in `@SceneStorage`
/// and resolved against live data after the sidecar answers, so restoring a
/// window never creates, resumes, or ends a session.
struct WindowState: Equatable, RawRepresentable, Sendable {
    var destination: SidebarDestination = .projects
    var projectID: String?
    var sessionID: String?
    var isInspectorVisible = false
    var terminalLayout: TerminalLayout = .single

    /// Separate Codable payload: a type that is both Codable and
    /// RawRepresentable would encode through `rawValue` and recurse forever.
    private struct Payload: Codable {
        var destination: SidebarDestination
        var projectID: String?
        var sessionID: String?
        var isInspectorVisible: Bool
        var terminalLayout: TerminalLayout
    }

    init() {}

    init(
        destination: SidebarDestination,
        projectID: String? = nil,
        sessionID: String? = nil,
        isInspectorVisible: Bool = false,
        terminalLayout: TerminalLayout = .single
    ) {
        self.destination = destination
        self.projectID = projectID
        self.sessionID = sessionID
        self.isInspectorVisible = isInspectorVisible
        self.terminalLayout = terminalLayout
    }

    init?(rawValue: String) {
        guard
            let data = rawValue.data(using: .utf8),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return nil
        }
        destination = payload.destination
        projectID = payload.projectID
        sessionID = payload.sessionID
        isInspectorVisible = payload.isInspectorVisible
        terminalLayout = payload.terminalLayout
    }

    var rawValue: String {
        let payload = Payload(
            destination: destination,
            projectID: projectID,
            sessionID: sessionID,
            isInspectorVisible: isInspectorVisible,
            terminalLayout: terminalLayout
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard
            let data = try? encoder.encode(payload),
            let string = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return string
    }

    /// Field-wise equality; RawRepresentable's default would compare JSON text.
    static func == (lhs: WindowState, rhs: WindowState) -> Bool {
        lhs.destination == rhs.destination
            && lhs.projectID == rhs.projectID
            && lhs.sessionID == rhs.sessionID
            && lhs.isInspectorVisible == rhs.isInspectorVisible
            && lhs.terminalLayout == rhs.terminalLayout
    }

    /// Picks the stored project only if it still exists.
    func resolveProject(in projects: [ProjectDTO]) -> ProjectDTO? {
        guard let projectID else { return nil }
        return projects.first { $0.id == projectID }
    }

    /// Picks the stored session only if it still belongs to the resolved project.
    func resolveSession(in sessions: [SessionViewDTO], project: ProjectDTO?) -> SessionViewDTO? {
        guard let sessionID, let project else { return nil }
        return sessions.first { $0.id == sessionID && $0.session.repoPath == project.repoPath }
    }
}
