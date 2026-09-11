import Foundation
import Testing
@testable import OpenMultiAgent

@MainActor
struct SessionWorkspaceModelTests {
    @Test func loadingOlderTranscriptPrependsWithoutDuplicates() async {
        let client = WorkspaceClientStub(pages: [
            nil: TranscriptPageDTO(items: [.event(seq: 3), .event(seq: 2)], nextCursor: "c2"),
            "c2": TranscriptPageDTO(items: [.event(seq: 2), .event(seq: 1), .event(seq: 0)], nextCursor: nil),
        ])
        let model = SessionWorkspaceModel(session: .sample(id: "s", status: "ended"), client: client, transcriptPageSize: 2)

        await model.loadNewestTranscript()
        #expect(model.events.map(\.sequence) == [2, 3])
        #expect(model.canLoadOlderTranscript)

        await model.loadOlderTranscript()
        #expect(model.events.map(\.sequence) == [0, 1, 2, 3])
        #expect(model.nextCursor == nil)
        #expect(model.canLoadOlderTranscript == false)
    }

    @Test func applyCannotRunBeforePreview() async {
        let client = WorkspaceClientStub(extractCount: 2, preview: PromotionPreviewDTO(diff: "+++ .oma/docs/decisions.md", candidateCount: 2))
        let model = SessionWorkspaceModel(session: .sample(id: "s", status: "ended"), client: client)

        #expect(model.canApplyPromotion == false)
        await model.applyPromotion()
        #expect(await client.applyCalls == 0)

        await model.extractKnowledge()
        #expect(model.route == .promotionPreview)
        #expect(model.promotion == .preview(diff: "+++ .oma/docs/decisions.md", count: 2))
        #expect(model.canApplyPromotion)

        await model.applyPromotion()
        #expect(model.promotion == .applied(files: ["/repo/.oma/docs/decisions.md"]))
        #expect(model.hasReviewableCandidates == false)
        #expect(await client.applyCalls == 1)
    }

    @Test func failedExtractionKeepsTheSessionEndedAndOffersRetry() async {
        let client = WorkspaceClientStub(extractError: RPCErrorDTO(code: -32005, message: "Model unavailable"))
        let model = SessionWorkspaceModel(session: .sample(id: "s", status: "ended"), client: client)

        await model.extractKnowledge()

        #expect(model.session.session.isActive == false)
        #expect(model.promotion == .failed(message: "Model unavailable", recovery: .retry))
        #expect(model.route == .promotionPreview)
        #expect(model.canApplyPromotion == false)
    }

    @Test func extractionIsOnlyOfferedForEndedSessions() async {
        let client = WorkspaceClientStub(extractCount: 1)
        let model = SessionWorkspaceModel(session: .sample(id: "s", status: "active"), client: client)

        #expect(model.canExtract == false)
        await model.extractKnowledge()
        #expect(await client.extractCalls == 0)
    }

    @Test func memorySearchOnlySendsTheSettledQuery() async {
        let client = WorkspaceClientStub()
        let model = MemorySearchModel(client: client, repoPath: "/repo", debounce: .milliseconds(30))

        model.updateQuery("Sw")
        model.updateQuery("Swi")
        model.updateQuery("SwiftUI")
        try? await Task.sleep(for: .milliseconds(150))

        #expect(model.executedQueries == ["SwiftUI"])
        #expect(model.hits.count == 1)
        #expect(model.isSearching == false)
    }

    @Test func autoCheckLoopUpdatesCandidateCountForAnActiveSession() async {
        let client = WorkspaceClientStub(autoCheckCandidateCount: 1)
        let model = SessionWorkspaceModel(
            session: .sample(id: "s", status: "active"),
            client: client,
            autoCheckInterval: .milliseconds(10)
        )

        model.startAutoCheckLoop()
        try? await Task.sleep(for: .milliseconds(60))
        await model.stopAutoCheckLoop()

        #expect(model.hasReviewableCandidates)
        #expect(await client.autoCheckCalls > 0)
    }

    @Test func autoCheckLoopNeverStartsForAnEndedSession() async {
        let client = WorkspaceClientStub(autoCheckCandidateCount: 1)
        let model = SessionWorkspaceModel(
            session: .sample(id: "s", status: "ended"),
            client: client,
            autoCheckInterval: .milliseconds(10)
        )

        model.startAutoCheckLoop()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await client.autoCheckCalls == 0)
    }

    @Test func endingASessionStopsTheAutoCheckLoop() async {
        let client = WorkspaceClientStub(autoCheckCandidateCount: 1)
        let model = SessionWorkspaceModel(
            session: .sample(id: "s", status: "active"),
            client: client,
            autoCheckInterval: .milliseconds(10)
        )
        model.startAutoCheckLoop()
        try? await Task.sleep(for: .milliseconds(25))

        _ = await model.endSession()
        let callsAtEnd = await client.autoCheckCalls
        try? await Task.sleep(for: .milliseconds(50))

        #expect(await client.autoCheckCalls == callsAtEnd)
    }

    /// Regression test for the finding that a background auto-check could
    /// silently replace the candidates behind an open review sheet: while
    /// `route` is set (the sheet is up, showing a preview the user hasn't
    /// acted on or dismissed yet), the loop must skip `promotionAutoCheck`
    /// entirely rather than re-extracting underneath it.
    @Test func autoCheckSkipsWhileARouteIsOpen() async {
        let client = WorkspaceClientStub(
            preview: PromotionPreviewDTO(diff: "+++ .oma/docs/decisions.md", candidateCount: 2),
            autoCheckCandidateCount: 1
        )
        let model = SessionWorkspaceModel(
            session: .sample(id: "s", status: "active"),
            client: client,
            autoCheckInterval: .milliseconds(10)
        )

        model.startAutoCheckLoop()
        await model.openPreview()
        #expect(model.route == .promotionPreview)

        try? await Task.sleep(for: .milliseconds(60))
        await model.stopAutoCheckLoop()

        #expect(await client.autoCheckCalls == 0)
    }
}

private actor WorkspaceClientStub: DesktopAPI {
    let pages: [String?: TranscriptPageDTO]
    let extractCount: Int
    let extractError: RPCErrorDTO?
    let preview: PromotionPreviewDTO?
    let autoCheckCandidateCount: Int
    var applyCalls = 0
    var extractCalls = 0
    var autoCheckCalls = 0

    init(
        pages: [String?: TranscriptPageDTO] = [:],
        extractCount: Int = 0,
        extractError: RPCErrorDTO? = nil,
        preview: PromotionPreviewDTO? = nil,
        autoCheckCandidateCount: Int = 0
    ) {
        self.pages = pages
        self.extractCount = extractCount
        self.extractError = extractError
        self.preview = preview
        self.autoCheckCandidateCount = autoCheckCandidateCount
    }

    func hello() async throws -> HelloDTO { HelloDTO(protocolVersion: 1, appVersion: "test", agents: []) }
    func health() async throws -> HealthDTO { HealthDTO(ok: true, tmuxAvailable: true) }
    func listProjects() async throws -> [ProjectDTO] { [] }
    func addProject(repoPath: String, displayName: String?) async throws -> ProjectDTO { throw SidecarClientError.invalidResponse }
    func removeProject(id: String) async throws {}
    func transcript(sessionID: String, before: String?, limit: Int) async throws -> TranscriptPageDTO {
        guard let page = pages[before] else { throw SidecarClientError.invalidResponse }
        return page
    }
    func extractKnowledge(sessionID: String) async throws -> ExtractResultDTO {
        extractCalls += 1
        if let extractError { throw extractError }
        return ExtractResultDTO(candidateCount: extractCount)
    }
    func previewPromotion(sessionID: String) async throws -> PromotionPreviewDTO {
        try #require(preview)
    }
    func applyPromotion(sessionID: String) async throws -> PromotionApplyDTO {
        applyCalls += 1
        return PromotionApplyDTO(promoted: 2, files: ["/repo/.oma/docs/decisions.md"])
    }
    func searchMemory(query: String, repoPath: String?, limit: Int) async throws -> [SearchHitDTO] {
        [.memory(MemorySearchHitDTO(id: "m", kind: .decision, scope: "repo", repoPath: repoPath, title: query, body: "",
                                    confidence: 1, createdAt: Date(timeIntervalSince1970: 1), sourceSessionID: nil, score: -1))]
    }
    func listMemory(repoPath: String?, limit: Int) async throws -> [MemoryDTO] { [] }
    func promotionAutoCheck(sessionID: String) async throws -> ExtractResultDTO {
        autoCheckCalls += 1
        return ExtractResultDTO(candidateCount: autoCheckCandidateCount)
    }
    func endSession(id: String) async throws {}
}

private extension TranscriptEventDTO {
    static func event(seq: Int) -> TranscriptEventDTO {
        TranscriptEventDTO(id: "e\(seq)", sessionID: "s", agentRunID: "run-1", sequence: seq,
                           timestamp: Date(timeIntervalSince1970: TimeInterval(seq)), role: "assistant",
                           kind: "text", toolName: nil, text: "event \(seq)")
    }
}
