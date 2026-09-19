import Foundation

struct HelloDTO: Decodable, Equatable, Sendable {
    let protocolVersion: Int
    let appVersion: String
    let agents: [String]

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case appVersion = "app_version"
        case agents
    }
}

struct HealthDTO: Decodable, Equatable, Sendable {
    let ok: Bool
    let tmuxAvailable: Bool

    private enum CodingKeys: String, CodingKey {
        case ok
        case tmuxAvailable = "tmux_available"
    }
}

struct ProjectDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let repoPath: String
    let displayName: String
    let createdAt: Date
    let lastOpenedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case repoPath = "repo_path"
        case displayName = "display_name"
        case createdAt = "created_at"
        case lastOpenedAt = "last_opened_at"
    }
}

struct SessionDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let repoPath: String
    let worktreePath: String?
    let branch: String?
    let title: String?
    let status: String
    let startedAt: Date
    let endedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case repoPath = "repo_path"
        case worktreePath = "worktree_path"
        case branch
        case title
        case status
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct AgentRunDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let agent: String
    let nativeSessionID: String?
    let transcriptPath: String?
    let startedAt: Date
    let endedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case agent
        case nativeSessionID = "native_session_id"
        case transcriptPath = "transcript_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

struct ChangedFileDTO: Decodable, Equatable, Identifiable, Sendable {
    var id: String { path }

    let path: String
    let status: String
}

struct SessionStatusDTO: Decodable, Equatable, Sendable {
    let session: SessionDTO
    let runs: [AgentRunDTO]
    let tmuxAlive: Bool
    let changedFiles: [ChangedFileDTO]
    let diffStat: String
    let pane: String?

    private enum CodingKeys: String, CodingKey {
        case session
        case runs
        case tmuxAlive = "tmux_alive"
        case changedFiles = "changed_files"
        case diffStat = "diff_stat"
        case pane
    }
}

struct SessionViewDTO: Decodable, Equatable, Identifiable, Sendable {
    var id: String { session.id }

    let session: SessionDTO
    let runs: [AgentRunDTO]
    let tmuxAlive: Bool

    private enum CodingKeys: String, CodingKey {
        case session
        case runs
        case tmuxAlive = "tmux_alive"
    }
}

struct ProjectDetailDTO: Decodable, Equatable, Sendable {
    let project: ProjectDTO
    let sessions: [SessionViewDTO]
}

struct AgentKind: Codable, Hashable, Identifiable, Sendable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let claude = AgentKind(rawValue: "claude")
    static let codex = AgentKind(rawValue: "codex")
    static let gemini = AgentKind(rawValue: "gemini")
    static let terminal = AgentKind(rawValue: "terminal")

    static var builtins: [AgentKind] { [.claude, .codex, .gemini] }
    static var allCases: [AgentKind] { builtins + [.terminal] }

    var id: String { rawValue }

    var title: String {
        rawValue
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }

    var isBuiltin: Bool { Self.builtins.contains(self) }

    var symbol: String {
        switch rawValue {
        case "claude": "sparkles"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "gemini": "diamond.fill"
        default: "terminal"
        }
    }

    func resolvedSymbol(in customAgents: [CustomAgentDTO]) -> String {
        customAgents.first { $0.id == rawValue }?.symbol ?? symbol
    }
}

struct CustomAgentDTO: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let binary: String
    let launchArgs: [String]
    let symbol: String

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case binary
        case launchArgs = "launch_args"
        case symbol
    }

    init(id: String, name: String, binary: String, launchArgs: [String], symbol: String = "terminal") {
        self.id = id
        self.name = name
        self.binary = binary
        self.launchArgs = launchArgs
        self.symbol = symbol.isEmpty ? "terminal" : symbol
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        binary = try container.decode(String.self, forKey: .binary)
        launchArgs = try container.decode([String].self, forKey: .launchArgs)
        let decoded = try container.decodeIfPresent(String.self, forKey: .symbol) ?? "terminal"
        symbol = decoded.isEmpty ? "terminal" : decoded
    }
}

struct AgentSystemPromptDTO: Codable, Equatable, Sendable {
    let agent: String
    let systemPrompt: String

    private enum CodingKeys: String, CodingKey {
        case agent
        case systemPrompt = "system_prompt"
    }
}

struct NewSessionRequest: Equatable, Sendable {
    let repoPath: String
    let agent: AgentKind
    let usesWorktree: Bool
    let title: String?
    let prompt: String?
}

struct TerminalAttachmentDTO: Decodable, Equatable, Sendable {
    let executable: String
    let arguments: [String]
    let cwd: String
}

struct TranscriptEventDTO: Decodable, Equatable, Identifiable, Sendable {
    var identity: String { "\(agentRunID):\(sequence)" }

    let id: String
    let sessionID: String
    let agentRunID: String
    let sequence: Int
    let timestamp: Date
    let role: String
    let kind: String
    let toolName: String?
    let text: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case agentRunID = "agent_run_id"
        case sequence = "seq"
        case timestamp = "ts"
        case role
        case kind
        case toolName = "tool_name"
        case text
    }
}

struct TranscriptPageDTO: Decodable, Equatable, Sendable {
    let items: [TranscriptEventDTO]
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

// MARK: - Sessions

extension SessionDTO {
    var isActive: Bool { status == "active" }
    var displayTitle: String { title ?? "Naamloze sessie" }
    var usesWorktree: Bool { worktreePath != nil && worktreePath != repoPath }
}

extension SessionViewDTO {
    var currentAgent: AgentKind? {
        runs.last.map { AgentKind(rawValue: $0.agent) }
    }
}

extension SessionStatusDTO {
    var view: SessionViewDTO { SessionViewDTO(session: session, runs: runs, tmuxAlive: tmuxAlive) }
}

struct EndedSessionDTO: Decodable, Equatable, Sendable {
    let endedSessionID: String
    let merged: Bool?

    private enum CodingKeys: String, CodingKey {
        case endedSessionID = "ended_session_id"
        case merged
    }
}

struct RemovedSessionDTO: Decodable, Equatable, Sendable {
    let removedSessionID: String

    private enum CodingKeys: String, CodingKey {
        case removedSessionID = "removed_session_id"
    }
}

// MARK: - Memory

enum MemoryKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case decision
    case invariant
    case risk
    case ownership
    case howto

    var id: Self { self }

    var title: String {
        switch self {
        case .decision: "Beslissing"
        case .invariant: "Invariant"
        case .risk: "Risico"
        case .ownership: "Eigenaarschap"
        case .howto: "How-to"
        }
    }

    var symbol: String {
        switch self {
        case .decision: "checkmark.seal"
        case .invariant: "lock.shield"
        case .risk: "exclamationmark.triangle"
        case .ownership: "person.crop.circle"
        case .howto: "book"
        }
    }
}

struct MemoryDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: MemoryKind
    let scope: String
    let repoPath: String?
    let title: String
    let body: String
    let confidence: Double
    let sourceSessionID: String?
    let createdAt: Date
    let supersededBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case scope
        case repoPath = "repo_path"
        case title
        case body
        case confidence
        case sourceSessionID = "source_session_id"
        case createdAt = "created_at"
        case supersededBy = "superseded_by"
    }
}

struct MemorySearchHitDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let kind: MemoryKind
    let scope: String
    let repoPath: String?
    let title: String
    let body: String
    let confidence: Double
    let createdAt: Date
    let sourceSessionID: String?
    let score: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case scope
        case repoPath = "repo_path"
        case title
        case body
        case confidence
        case createdAt = "created_at"
        case sourceSessionID = "source_session_id"
        case score
    }
}

struct EventSearchHitDTO: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let sessionID: String
    let agent: String
    let timestamp: Date
    let role: String
    let kind: String
    let toolName: String?
    let text: String
    let score: Double

    private enum CodingKeys: String, CodingKey {
        case id
        case sessionID = "session_id"
        case agent
        case timestamp = "ts"
        case role
        case kind
        case toolName = "tool_name"
        case text
        case score
    }
}

enum SearchHitDTO: Decodable, Equatable, Identifiable, Sendable {
    case memory(MemorySearchHitDTO)
    case event(EventSearchHitDTO)

    var id: String {
        switch self {
        case .memory(let hit): "memory:\(hit.id)"
        case .event(let hit): "event:\(hit.id)"
        }
    }

    private enum TypeKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: TypeKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "memory":
            self = .memory(try MemorySearchHitDTO(from: decoder))
        case "event":
            self = .event(try EventSearchHitDTO(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown search hit type: \(type)"
            )
        }
    }
}

// MARK: - Living docs and promotion

struct LivingDocDTO: Decodable, Equatable, Identifiable, Sendable {
    var id: String { path }

    let kind: MemoryKind
    let path: String
    let title: String
    let modifiedAt: Date

    private enum CodingKeys: String, CodingKey {
        case kind
        case path
        case title
        case modifiedAt = "modified_at"
    }
}

struct ExtractResultDTO: Decodable, Equatable, Sendable {
    let candidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case candidateCount = "candidate_count"
    }
}

struct PromotionPreviewDTO: Decodable, Equatable, Sendable {
    let diff: String
    let candidateCount: Int

    private enum CodingKeys: String, CodingKey {
        case diff
        case candidateCount = "candidate_count"
    }
}

struct PromotionApplyDTO: Decodable, Equatable, Sendable {
    let promoted: Int
    let files: [String]
}

struct PendingPromotionCountDTO: Decodable, Equatable, Sendable {
    let count: Int
}

// MARK: - Project editor

struct FileTreeDTO: Decodable, Equatable, Sendable {
    let paths: [String]
}

struct FileContentDTO: Decodable, Equatable, Sendable {
    let path: String
    let content: String
}

struct FileWriteDTO: Decodable, Equatable, Sendable {
    let path: String
    let bytesWritten: Int

    private enum CodingKeys: String, CodingKey {
        case path
        case bytesWritten = "bytes_written"
    }
}

struct FileDiffDTO: Decodable, Equatable, Sendable {
    let path: String
    let diff: String
}
