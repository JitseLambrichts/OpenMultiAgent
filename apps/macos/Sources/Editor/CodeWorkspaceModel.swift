import Foundation
import Observation

enum CodeRoot: Hashable, Identifiable, Sendable {
    case project
    case session(id: String)

    var id: String {
        switch self {
        case .project: "project"
        case .session(let id): "session:\(id)"
        }
    }

    var sessionID: String? {
        switch self {
        case .project: nil
        case .session(let id): id
        }
    }
}

struct FileNode: Identifiable, Hashable, Sendable {
    var id: String { path }
    let name: String
    let path: String
    let children: [FileNode]?

    var isDirectory: Bool { children != nil }
}

struct OpenBuffer: Identifiable, Equatable, Sendable {
    var id: String { path }
    let path: String
    var content: String
    var savedContent: String

    var isDirty: Bool { content != savedContent }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

enum FileTreeBuilder {
    static func nodes(from paths: [String]) -> [FileNode] {
        final class Draft {
            let name: String
            let path: String
            var children: [String: Draft] = [:]
            var isFile = false

            init(name: String, path: String) {
                self.name = name
                self.path = path
            }

            func node() -> FileNode {
                if isFile && children.isEmpty {
                    return FileNode(name: name, path: path, children: nil)
                }
                return FileNode(
                    name: name,
                    path: path,
                    children: children.values.map { $0.node() }.sorted(by: FileTreeBuilder.order)
                )
            }
        }

        let root = Draft(name: "", path: "")
        for path in paths {
            let parts = path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else { continue }
            var current = root
            var prefix = ""
            for (index, part) in parts.enumerated() {
                prefix = prefix.isEmpty ? part : "\(prefix)/\(part)"
                if current.children[part] == nil {
                    current.children[part] = Draft(name: part, path: prefix)
                }
                current = current.children[part]!
                if index == parts.count - 1 {
                    current.isFile = true
                }
            }
        }
        return root.children.values.map { $0.node() }.sorted(by: order)
    }

    fileprivate static func order(_ lhs: FileNode, _ rhs: FileNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

@MainActor
@Observable
final class CodeWorkspaceModel {
    let project: ProjectDTO
    @ObservationIgnored let client: any DesktopAPI

    private(set) var root: CodeRoot = .project
    private(set) var tree: [FileNode] = []
    private(set) var buffers: [OpenBuffer] = []
    var selectedPath: String?
    private(set) var isLoading = false
    private(set) var isSaving = false
    private(set) var notice: String?

    init(project: ProjectDTO, client: any DesktopAPI) {
        self.project = project
        self.client = client
    }

    var selectedBuffer: OpenBuffer? {
        guard let selectedPath else { return nil }
        return buffers.first { $0.path == selectedPath }
    }

    var hasDirtyBuffers: Bool {
        buffers.contains { $0.isDirty }
    }

    var selectedIsDirty: Bool {
        selectedBuffer?.isDirty == true
    }

    func loadTree() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await client.fsTree(projectID: project.id, sessionID: root.sessionID)
            tree = FileTreeBuilder.nodes(from: result.paths)
            notice = nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func selectRoot(_ next: CodeRoot) async {
        guard next != root else { return }
        if hasDirtyBuffers {
            notice = "Save changes before switching worktrees."
            return
        }
        root = next
        buffers = []
        selectedPath = nil
        await loadTree()
    }

    func openFile(_ path: String) async {
        if let index = buffers.firstIndex(where: { $0.path == path }) {
            selectedPath = buffers[index].path
            return
        }
        do {
            let file = try await client.fsRead(projectID: project.id, sessionID: root.sessionID, path: path)
            buffers.append(OpenBuffer(path: file.path, content: file.content, savedContent: file.content))
            selectedPath = file.path
            notice = nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func reveal(path: String, sessionID: String?) async {
        let next: CodeRoot = sessionID.map { .session(id: $0) } ?? .project
        if next != root {
            if hasDirtyBuffers {
                notice = "Save changes before switching worktrees."
                return
            }
            root = next
            buffers = []
            selectedPath = nil
            await loadTree()
        }
        await openFile(path)
    }

    func updateContent(_ content: String, for path: String) {
        guard let index = buffers.firstIndex(where: { $0.path == path }) else { return }
        buffers[index].content = content
    }

    func closeBuffer(_ path: String) {
        buffers.removeAll { $0.path == path }
        if selectedPath == path {
            selectedPath = buffers.last?.path
        }
    }

    @discardableResult
    func saveSelected() async -> Bool {
        guard let path = selectedPath else { return false }
        return await save(path: path)
    }

    @discardableResult
    func save(path: String) async -> Bool {
        guard let index = buffers.firstIndex(where: { $0.path == path }) else { return false }
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await client.fsWrite(
                projectID: project.id,
                sessionID: root.sessionID,
                path: path,
                content: buffers[index].content
            )
            buffers[index].savedContent = buffers[index].content
            notice = nil
            return true
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    func reloadCleanBuffers() async {
        for index in buffers.indices where !buffers[index].isDirty {
            let path = buffers[index].path
            if let file = try? await client.fsRead(projectID: project.id, sessionID: root.sessionID, path: path) {
                buffers[index].content = file.content
                buffers[index].savedContent = file.content
            }
        }
        await loadTree()
    }
}