import Foundation

struct RPCLineBuffer: Sendable {
    private var storage = Data()

    mutating func append(_ chunk: Data) -> [Data] {
        storage.append(chunk)
        var lines: [Data] = []

        while let newline = storage.firstIndex(of: 0x0A) {
            let line = storage[..<newline]
            storage.removeSubrange(...newline)
            let trimmed = Data(line).trimmingASCIIWhitespace()
            if !trimmed.isEmpty {
                lines.append(trimmed)
            }
        }
        return lines
    }

    mutating func flush() -> Data? {
        let remainder = storage.trimmingASCIIWhitespace()
        storage.removeAll(keepingCapacity: true)
        return remainder.isEmpty ? nil : remainder
    }
}

private extension Data {
    func trimmingASCIIWhitespace() -> Data {
        let whitespace: Set<UInt8> = [0x09, 0x0A, 0x0D, 0x20]
        guard
            let first = firstIndex(where: { !whitespace.contains($0) }),
            let last = lastIndex(where: { !whitespace.contains($0) })
        else {
            return Data()
        }
        return Data(self[first...last])
    }
}

/// Where the sidecar comes from. Resolution order: an explicit environment
/// override (used by UI tests and fixtures), a compiled binary embedded in the
/// app bundle, and finally the development checkout run through Bun.
struct SidecarConfiguration: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case environment
        case bundled
        case development
    }

    let executableURL: URL
    let arguments: [String]
    let workspaceRoot: URL
    let source: Source

    static let environmentExecutableKey = "OMA_DESKTOP_SIDECAR"
    static let environmentArgumentsKey = "OMA_DESKTOP_SIDECAR_ARGS"
    static let bundledExecutableName = "oma-desktop-api"

    static var checkoutRoot: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            root.deleteLastPathComponent()
        }
        return root
    }

    static var development: SidecarConfiguration {
        SidecarConfiguration(
            executableURL: URL(fileURLWithPath: bunExecutable()),
            arguments: ["run", "packages/desktop-api/src/index.ts"],
            workspaceRoot: checkoutRoot,
            source: .development
        )
    }

    /// Apps launched from Finder or Xcode get a minimal PATH, so Bun is
    /// resolved from PATH first and then from its usual install locations.
    static func bunExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let fromPath = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/bun" }
        let candidates = fromPath + [
            "\(home)/.bun/bin/bun",
            "/opt/homebrew/bin/bun",
            "/usr/local/bin/bun",
        ]
        return candidates.first(where: fileExists) ?? "/usr/bin/env"
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> SidecarConfiguration {
        if let executable = environment[environmentExecutableKey], !executable.isEmpty {
            let arguments = environment[environmentArgumentsKey]?
                .split(separator: "\u{1F}")
                .map(String.init) ?? []
            return SidecarConfiguration(
                executableURL: URL(fileURLWithPath: executable),
                arguments: arguments,
                workspaceRoot: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
                source: .environment
            )
        }
        if let bundled = bundle.url(forResource: bundledExecutableName, withExtension: nil),
           fileExists(bundled.path) {
            return SidecarConfiguration(
                executableURL: bundled,
                arguments: [],
                workspaceRoot: bundled.deletingLastPathComponent(),
                source: .bundled
            )
        }
        return .development
    }
}

enum SidecarClientError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case disconnected(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            "De OpenMultiAgent-service kon niet starten. \(detail)"
        case .disconnected(let detail):
            "De OpenMultiAgent-service is gestopt. \(detail)"
        case .invalidResponse:
            "De OpenMultiAgent-service stuurde een ongeldig antwoord."
        }
    }
}

/// Env-gated diagnostics (`OMA_DESKTOP_DEBUG=1`, optional `OMA_DESKTOP_DEBUG_LOG`).
/// Used by the sidecar transport and by lifecycle-critical model operations.
enum DebugTrace {
    nonisolated(unsafe) private static let handle: FileHandle? = {
        guard ProcessInfo.processInfo.environment["OMA_DESKTOP_DEBUG"] == "1" else { return nil }
        guard let path = ProcessInfo.processInfo.environment["OMA_DESKTOP_DEBUG_LOG"], !path.isEmpty else {
            return FileHandle.standardError
        }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: path)
        _ = try? handle?.seekToEnd()
        return handle
    }()

    static func log(_ message: @autoclosure () -> String) {
        guard let handle else { return }
        handle.write(Data("[trace] \(message())\n".utf8))
    }
}

enum SidecarEvent: Sendable, Equatable {
    case disconnected(detail: String)
}

/// Every call the desktop app makes. Feature models depend on this protocol so
/// tests can substitute deterministic stubs; only `SidecarClient` talks JSON-RPC.
protocol DesktopAPI: Sendable {
    func hello() async throws -> HelloDTO
    func health() async throws -> HealthDTO
    func listProjects() async throws -> [ProjectDTO]
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO
    func removeProject(id: String) async throws
    func projectDetail(id: String) async throws -> ProjectDetailDTO
    func listSessions(repoPath: String?, status: String?) async throws -> [SessionViewDTO]
    func sessionStatus(id: String) async throws -> SessionStatusDTO
    func createSession(_ request: NewSessionRequest) async throws -> SessionViewDTO
    func resumeSession(id: String) async throws -> SessionViewDTO
    func switchSession(id: String, agent: AgentKind, prompt: String?) async throws -> SessionViewDTO
    func endSession(id: String) async throws
    func removeSession(id: String, force: Bool, keepWorktree: Bool) async throws
    func transcript(sessionID: String, before: String?, limit: Int) async throws -> TranscriptPageDTO
    func listMemory(repoPath: String?, limit: Int) async throws -> [MemoryDTO]
    func searchMemory(query: String, repoPath: String?, limit: Int) async throws -> [SearchHitDTO]
    func listDocs(repoPath: String) async throws -> [LivingDocDTO]
    func extractKnowledge(sessionID: String) async throws -> ExtractResultDTO
    func previewPromotion(sessionID: String) async throws -> PromotionPreviewDTO
    func applyPromotion(sessionID: String) async throws -> PromotionApplyDTO
    func terminalAttachment(sessionID: String) async throws -> TerminalAttachmentDTO
    func listCustomAgents() async throws -> [CustomAgentDTO]
    func addCustomAgent(name: String, binary: String, launchArgs: [String], symbol: String) async throws -> CustomAgentDTO
    func updateCustomAgent(id: String, name: String, binary: String, launchArgs: [String], symbol: String) async throws -> CustomAgentDTO
    func removeCustomAgent(id: String) async throws
}

/// Defaults keep focused test stubs small: a stub only implements the calls the
/// model under test exercises, everything else reports itself unavailable.
extension DesktopAPI {
    private var notWired: SidecarClientError { .unavailable("Deze functie is niet beschikbaar.") }

    func projectDetail(id: String) async throws -> ProjectDetailDTO { throw notWired }
    func listSessions(repoPath: String?, status: String?) async throws -> [SessionViewDTO] { throw notWired }
    func sessionStatus(id: String) async throws -> SessionStatusDTO { throw notWired }
    func createSession(_ request: NewSessionRequest) async throws -> SessionViewDTO { throw notWired }
    func resumeSession(id: String) async throws -> SessionViewDTO { throw notWired }
    func switchSession(id: String, agent: AgentKind, prompt: String?) async throws -> SessionViewDTO { throw notWired }
    func endSession(id: String) async throws { throw notWired }
    func removeSession(id: String, force: Bool, keepWorktree: Bool) async throws { throw notWired }
    func transcript(sessionID: String, before: String?, limit: Int) async throws -> TranscriptPageDTO { throw notWired }
    func listMemory(repoPath: String?, limit: Int) async throws -> [MemoryDTO] { throw notWired }
    func searchMemory(query: String, repoPath: String?, limit: Int) async throws -> [SearchHitDTO] { throw notWired }
    func listDocs(repoPath: String) async throws -> [LivingDocDTO] { throw notWired }
    func extractKnowledge(sessionID: String) async throws -> ExtractResultDTO { throw notWired }
    func previewPromotion(sessionID: String) async throws -> PromotionPreviewDTO { throw notWired }
    func applyPromotion(sessionID: String) async throws -> PromotionApplyDTO { throw notWired }
    func terminalAttachment(sessionID: String) async throws -> TerminalAttachmentDTO { throw notWired }
    func listCustomAgents() async throws -> [CustomAgentDTO] { throw notWired }
    func addCustomAgent(name: String, binary: String, launchArgs: [String], symbol: String) async throws -> CustomAgentDTO { throw notWired }
    func updateCustomAgent(id: String, name: String, binary: String, launchArgs: [String], symbol: String) async throws -> CustomAgentDTO { throw notWired }
    func removeCustomAgent(id: String) async throws { throw notWired }
}

actor SidecarClient: DesktopAPI {
    private struct ResponseHeader: Decodable {
        let id: Int?
    }

    private struct ShutdownDTO: Decodable, Sendable {
        let shuttingDown: Bool

        private enum CodingKeys: String, CodingKey {
            case shuttingDown = "shutting_down"
        }
    }

    private struct RemovedProjectDTO: Decodable, Sendable {
        let removedProjectID: String

        private enum CodingKeys: String, CodingKey {
            case removedProjectID = "removed_project_id"
        }
    }

    private struct RemovedAgentDTO: Decodable, Sendable {
        let removedAgentID: String

        private enum CodingKeys: String, CodingKey {
            case removedAgentID = "removed_agent_id"
        }
    }

    let configuration: SidecarConfiguration
    nonisolated let events: AsyncStream<SidecarEvent>
    private let eventContinuation: AsyncStream<SidecarEvent>.Continuation

    private var process: Process?
    private var inputHandle: FileHandle?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var responseBuffer = RPCLineBuffer()
    private var errorOutput = Data()
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<Data, any Error>] = [:]
    private func trace(_ direction: String, _ data: Data) {
        DebugTrace.log("sidecar \(direction) \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    init(configuration: SidecarConfiguration = .resolve()) {
        self.configuration = configuration
        let (stream, continuation) = AsyncStream<SidecarEvent>.makeStream()
        events = stream
        eventContinuation = continuation
    }

    // MARK: DesktopAPI

    func hello() async throws -> HelloDTO {
        try await request(method: "system.hello")
    }

    func health() async throws -> HealthDTO {
        try await request(method: "system.health")
    }

    func listProjects() async throws -> [ProjectDTO] {
        try await request(method: "project.list")
    }

    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO {
        var params: [String: JSONValue] = ["repo_path": .string(repoPath)]
        if let displayName, !displayName.isEmpty {
            params["display_name"] = .string(displayName)
        }
        return try await request(method: "project.add", params: params)
    }

    func removeProject(id: String) async throws {
        let _: RemovedProjectDTO = try await request(
            method: "project.remove",
            params: ["project_id": .string(id)]
        )
    }

    func projectDetail(id: String) async throws -> ProjectDetailDTO {
        try await request(method: "project.detail", params: ["project_id": .string(id)])
    }

    func listSessions(repoPath: String?, status: String?) async throws -> [SessionViewDTO] {
        var params: [String: JSONValue] = [:]
        if let repoPath { params["repo_path"] = .string(repoPath) }
        if let status { params["status"] = .string(status) }
        return try await request(method: "session.list", params: params)
    }

    func sessionStatus(id: String) async throws -> SessionStatusDTO {
        try await request(method: "session.status", params: ["session_id": .string(id)])
    }

    func createSession(_ newSession: NewSessionRequest) async throws -> SessionViewDTO {
        var params: [String: JSONValue] = [
            "repo_path": .string(newSession.repoPath),
            "agent": .string(newSession.agent.rawValue),
            "worktree": .bool(newSession.usesWorktree),
        ]
        if let title = newSession.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            params["title"] = .string(title)
        }
        if let prompt = newSession.prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            params["prompt"] = .string(prompt)
        }
        return try await request(method: "session.create", params: params)
    }

    func resumeSession(id: String) async throws -> SessionViewDTO {
        try await request(method: "session.resume", params: ["session_id": .string(id)])
    }

    func switchSession(id: String, agent: AgentKind, prompt: String?) async throws -> SessionViewDTO {
        var params: [String: JSONValue] = [
            "session_id": .string(id),
            "agent": .string(agent.rawValue),
        ]
        if let prompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty {
            params["prompt"] = .string(prompt)
        }
        return try await request(method: "session.switch", params: params)
    }

    func endSession(id: String) async throws {
        let _: EndedSessionDTO = try await request(
            method: "session.end",
            params: ["session_id": .string(id)]
        )
    }

    func removeSession(id: String, force: Bool, keepWorktree: Bool) async throws {
        let _: RemovedSessionDTO = try await request(
            method: "session.remove",
            params: [
                "session_id": .string(id),
                "force": .bool(force),
                "keep_worktree": .bool(keepWorktree),
            ]
        )
    }

    func transcript(sessionID: String, before: String?, limit: Int) async throws -> TranscriptPageDTO {
        var params: [String: JSONValue] = [
            "session_id": .string(sessionID),
            "limit": .integer(limit),
        ]
        if let before { params["before"] = .string(before) }
        return try await request(method: "transcript.list", params: params)
    }

    func listMemory(repoPath: String?, limit: Int) async throws -> [MemoryDTO] {
        var params: [String: JSONValue] = ["limit": .integer(limit)]
        if let repoPath { params["repo_path"] = .string(repoPath) }
        return try await request(method: "memory.list", params: params)
    }

    func searchMemory(query: String, repoPath: String?, limit: Int) async throws -> [SearchHitDTO] {
        var params: [String: JSONValue] = [
            "query": .string(query),
            "limit": .integer(limit),
        ]
        if let repoPath { params["repo_path"] = .string(repoPath) }
        return try await request(method: "memory.search", params: params)
    }

    func listDocs(repoPath: String) async throws -> [LivingDocDTO] {
        try await request(method: "docs.list", params: ["repo_path": .string(repoPath)])
    }

    func extractKnowledge(sessionID: String) async throws -> ExtractResultDTO {
        try await request(method: "promotion.extract", params: ["session_id": .string(sessionID)])
    }

    func previewPromotion(sessionID: String) async throws -> PromotionPreviewDTO {
        try await request(method: "promotion.preview", params: ["session_id": .string(sessionID)])
    }

    func applyPromotion(sessionID: String) async throws -> PromotionApplyDTO {
        try await request(method: "promotion.apply", params: ["session_id": .string(sessionID)])
    }

    func terminalAttachment(sessionID: String) async throws -> TerminalAttachmentDTO {
        try await request(method: "terminal.attachment", params: ["session_id": .string(sessionID)])
    }

    func listCustomAgents() async throws -> [CustomAgentDTO] {
        try await request(method: "agent.list")
    }

    func addCustomAgent(name: String, binary: String, launchArgs: [String], symbol: String) async throws -> CustomAgentDTO {
        try await request(method: "agent.add", params: [
            "name": .string(name),
            "binary": .string(binary),
            "launch_args": .array(launchArgs.map(JSONValue.string)),
            "symbol": .string(symbol),
        ])
    }

    func updateCustomAgent(id: String, name: String, binary: String, launchArgs: [String], symbol: String) async throws -> CustomAgentDTO {
        try await request(method: "agent.update", params: [
            "id": .string(id),
            "name": .string(name),
            "binary": .string(binary),
            "launch_args": .array(launchArgs.map(JSONValue.string)),
            "symbol": .string(symbol),
        ])
    }

    func removeCustomAgent(id: String) async throws {
        let _: RemovedAgentDTO = try await request(
            method: "agent.remove",
            params: ["id": .string(id)]
        )
    }

    // MARK: Lifecycle

    var isRunning: Bool { process?.isRunning == true }

    func shutdown() async {
        guard process?.isRunning == true else { return }
        let _: ShutdownDTO? = try? await request(method: "system.shutdown")
    }

    // MARK: Transport

    private func request<Result: Decodable & Sendable>(
        method: String,
        params: [String: JSONValue] = [:]
    ) async throws -> Result {
        try startIfNeeded()

        let id = nextID
        nextID += 1
        let requestData = try RPCRequest.encode(id: id, method: method, params: params)
        let responseData = try await send(requestData, id: id)
        let response = try JSONDecoder.oma.decode(RPCResponse<Result>.self, from: responseData)

        if let error = response.error {
            throw error
        }
        guard let result = response.result else {
            throw SidecarClientError.invalidResponse
        }
        return result
    }

    private func startIfNeeded() throws {
        if process?.isRunning == true { return }

        let process = Process()
        // Resolve the login-shell PATH before any socket exists so the shell
        // (and anything it starts) can never inherit the sidecar's descriptors.
        let environment = Self.childEnvironment(loginShellPath: Self.loginShellPath())
        // stdin is a Unix socket pair rather than a pipe: Bun 1.2 only delivers
        // piped stdin after EOF, which would stall the very first request. A
        // socket is read as it arrives. stdout/stderr pipes behave correctly.
        let (parentInput, childInput) = try Self.makeSocketPair()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workspaceRoot
        process.environment = environment
        process.standardInput = childInput
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receiveError(data) }
        }
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            Task { await self?.didTerminate(status: status) }
        }

        trace("▶", Data("\(configuration.executableURL.path) \(configuration.arguments.joined(separator: " ")) (cwd \(configuration.workspaceRoot.path))".utf8))
        trace("env", Data(ProcessInfo.processInfo.environment.keys.sorted().joined(separator: ",").utf8))
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            try? parentInput.close()
            try? childInput.close()
            trace("✕", Data("launch failed: \(error.localizedDescription)".utf8))
            throw SidecarClientError.unavailable(error.localizedDescription)
        }
        // The child owns its end now; closing ours lets EOF propagate later.
        try? childInput.close()

        self.process = process
        inputHandle = parentInput
        outputPipe = output
        errorPipe = errors
        responseBuffer = RPCLineBuffer()
        errorOutput.removeAll(keepingCapacity: true)
    }

    /// The sidecar inherits the app environment minus dynamic-loader and test
    /// instrumentation variables (`DYLD_*`, `XCTest*`, …). Passing those on
    /// would inject the test harness into Bun and stall it.
    static func childEnvironment(
        from environment: [String: String] = ProcessInfo.processInfo.environment,
        loginShellPath: String? = nil,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [String: String] {
        var filtered = environment.filter { key, _ in
            !key.hasPrefix("DYLD_") && !key.hasPrefix("XCTest") && !key.hasPrefix("XCInject")
                && !key.hasPrefix("__XCODE") && !key.hasPrefix("__XPC_DYLD")
        }
        // Apps launched from Finder or Xcode inherit a minimal PATH; the sidecar
        // needs tmux, git, and the agent CLIs, so the login shell's PATH and the
        // usual tool locations are appended (deduplicated, original order first).
        var entries: [String] = []
        func add(_ path: String) {
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !entries.contains(trimmed) else { return }
            entries.append(trimmed)
        }
        (filtered["PATH"] ?? "").split(separator: ":").forEach { add(String($0)) }
        (loginShellPath ?? "").split(separator: ":").forEach { add(String($0)) }
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.local/bin",
         "/usr/bin", "/bin", "/usr/sbin", "/sbin"].forEach(add)
        filtered["PATH"] = entries.joined(separator: ":")
        return filtered
    }

    /// PATH as the user's login shell sees it. Cached; a wedged shell is ignored.
    nonisolated(unsafe) private static var cachedLoginShellPath: String??

    static func loginShellPath() -> String? {
        if let cached = cachedLoginShellPath { return cached }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = Pipe()
        var result: String?
        do {
            try process.run()
            let deadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
            } else {
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                result = output.isEmpty ? nil : output
            }
        } catch {
            result = nil
        }
        cachedLoginShellPath = .some(result)
        return result
    }

    private static func makeSocketPair() throws -> (parent: FileHandle, child: FileHandle) {
        var descriptors: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw SidecarClientError.unavailable("socketpair failed: \(String(cString: strerror(errno)))")
        }
        // Neither end may leak into other children the app spawns later.
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        return (
            FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
            FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        )
    }

    private func send(_ data: Data, id: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    trace("→", data)
                    try inputHandle?.write(contentsOf: data)
                } catch {
                    pending.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    private func receive(_ data: Data) {
        for line in responseBuffer.append(data) {
            trace("←", line)
            guard
                let header = try? JSONDecoder().decode(ResponseHeader.self, from: line),
                let id = header.id,
                let continuation = pending.removeValue(forKey: id)
            else {
                // Notifications and unknown ids are ignored; the reconciliation
                // pass in AppModel covers anything a missed notification implied.
                continue
            }
            continuation.resume(returning: line)
        }
    }

    private func receiveError(_ data: Data) {
        trace("stderr", data)
        errorOutput.append(data)
        if errorOutput.count > 8_192 {
            errorOutput = errorOutput.suffix(8_192)
        }
    }

    private func cancel(id: Int) {
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func didTerminate(status: Int32) {
        trace("✕", Data("exit \(status)".utf8))
        let detail = String(decoding: errorOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = detail.isEmpty ? "Exitcode \(status)." : detail
        failPending(with: .disconnected(message))
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        inputHandle = nil
        outputPipe = nil
        errorPipe = nil
        eventContinuation.yield(.disconnected(detail: message))
    }

    private func failPending(with error: SidecarClientError) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: error)
        }
    }
}
