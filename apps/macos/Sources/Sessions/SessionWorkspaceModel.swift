import Foundation
import Observation

enum WorkspaceTab: String, CaseIterable, Identifiable, Sendable {
    case terminal
    case changes
    case memory
    case transcript

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .changes: "Wijzigingen"
        case .memory: "Geheugen"
        case .transcript: "Transcript"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: "terminal"
        case .changes: "doc.badge.ellipsis"
        case .memory: "brain.head.profile"
        case .transcript: "text.bubble"
        }
    }
}

/// Explicit promotion state machine. Apply is only reachable from `preview`.
enum PromotionState: Equatable, Sendable {
    case idle
    case extracting
    case preview(diff: String, count: Int)
    case applying
    case applied(files: [String])
    case failed(message: String, recovery: RecoveryAction)
}

enum WorkspaceRoute: Equatable, Sendable {
    case promotionPreview
}

@MainActor
@Observable
final class SessionWorkspaceModel {
    @ObservationIgnored let client: any DesktopAPI
    @ObservationIgnored let transcriptPageSize: Int
    @ObservationIgnored let autoCheckInterval: Duration
    @ObservationIgnored private var autoCheckTask: Task<Void, Never>?

    private(set) var session: SessionViewDTO
    private(set) var status: SessionStatusDTO?
    private(set) var isLoadingStatus = false
    var tab: WorkspaceTab = .terminal

    /// Oldest first for display; pages arrive newest first from the sidecar.
    private(set) var events: [TranscriptEventDTO] = []
    private(set) var nextCursor: String?
    private(set) var isLoadingTranscript = false
    private(set) var hasLoadedTranscript = false

    private(set) var promotion: PromotionState = .idle
    private(set) var candidateCount = 0
    private(set) var route: WorkspaceRoute?
    private(set) var notice: String?
    private(set) var isEnding = false

    init(session: SessionViewDTO, client: any DesktopAPI, transcriptPageSize: Int = 50, autoCheckInterval: Duration = .seconds(300)) {
        self.session = session
        self.client = client
        self.transcriptPageSize = transcriptPageSize
        self.autoCheckInterval = autoCheckInterval
    }

    // MARK: Derived

    var canApplyPromotion: Bool {
        if case .preview = promotion { return true }
        return false
    }

    var hasReviewableCandidates: Bool { candidateCount > 0 }

    var canExtract: Bool {
        !session.session.isActive && promotion != .extracting && promotion != .applying
    }

    var canLoadOlderTranscript: Bool { nextCursor != nil && !isLoadingTranscript }

    var runtime: String {
        let end = session.session.endedAt ?? Date()
        let interval = max(0, end.timeIntervalSince(session.session.startedAt))
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = interval >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: interval) ?? "0s"
    }

    // MARK: Status

    func loadStatus() async {
        isLoadingStatus = true
        defer { isLoadingStatus = false }
        do {
            let loaded = try await client.sessionStatus(id: session.id)
            status = loaded
            session = loaded.view
            notice = nil
            if !session.session.isActive {
                await refreshCandidateCount()
            }
        } catch {
            notice = message(for: error)
        }
    }

    /// Preview is read-only, so it doubles as the "are there candidates?" probe.
    private func refreshCandidateCount() async {
        if let preview = try? await client.previewPromotion(sessionID: session.id) {
            candidateCount = preview.candidateCount
        }
    }

    // MARK: Transcript

    func loadNewestTranscript() async {
        guard !isLoadingTranscript else { return }
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }
        do {
            let page = try await client.transcript(sessionID: session.id, before: nil, limit: transcriptPageSize)
            events = page.items.reversed()
            nextCursor = page.nextCursor
            hasLoadedTranscript = true
            notice = nil
        } catch {
            notice = message(for: error)
        }
    }

    func loadOlderTranscript() async {
        guard let cursor = nextCursor, !isLoadingTranscript else { return }
        isLoadingTranscript = true
        defer { isLoadingTranscript = false }
        do {
            let page = try await client.transcript(sessionID: session.id, before: cursor, limit: transcriptPageSize)
            let known = Set(events.map(\.identity))
            let older = page.items.reversed().filter { !known.contains($0.identity) }
            events.insert(contentsOf: older, at: 0)
            nextCursor = page.nextCursor
            notice = nil
        } catch {
            notice = message(for: error)
        }
    }

    // MARK: Promotion

    /// Runs the reviewed extraction pipeline. Failure never undoes the session
    /// end and leaves a Try Again path; success opens the preview.
    func extractKnowledge() async {
        guard canExtract else { return }
        promotion = .extracting
        do {
            let result = try await client.extractKnowledge(sessionID: session.id)
            candidateCount = result.candidateCount
            if result.candidateCount == 0 {
                promotion = .idle
                notice = "Geen nieuwe kennis gevonden in dit transcript. Custom agents (zoals opencode) schrijven geen transcript weg, dus er valt niets te extraheren."
                return
            }
            await openPreview()
        } catch {
            promotion = .failed(message: message(for: error), recovery: recovery(for: error))
            route = .promotionPreview
        }
    }

    func openPreview() async {
        do {
            let preview = try await client.previewPromotion(sessionID: session.id)
            candidateCount = preview.candidateCount
            promotion = .preview(diff: preview.diff, count: preview.candidateCount)
            route = .promotionPreview
        } catch {
            promotion = .failed(message: message(for: error), recovery: recovery(for: error))
            route = .promotionPreview
        }
    }

    func applyPromotion() async {
        guard canApplyPromotion else { return }
        promotion = .applying
        do {
            let applied = try await client.applyPromotion(sessionID: session.id)
            promotion = .applied(files: applied.files)
            candidateCount = 0
        } catch {
            promotion = .failed(message: message(for: error), recovery: recovery(for: error))
        }
    }

    func retryPromotion() async {
        if case .failed = promotion {
            if candidateCount > 0 {
                await openPreview()
            } else {
                promotion = .idle
                await extractKnowledge()
            }
        }
    }

    func dismissRoute() {
        route = nil
        if case .applied = promotion { promotion = .idle }
        if case .failed = promotion { promotion = .idle }
    }

    /// Keeps this session's own candidate count current while its workspace
    /// is open, without requiring the user to end the session first. A
    /// no-op for ended sessions or if the loop is already running.
    func startAutoCheckLoop() {
        guard session.session.isActive, autoCheckTask == nil else { return }
        autoCheckTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: self.autoCheckInterval)
                if Task.isCancelled { break }
                await self.performAutoCheck()
            }
        }
    }

    /// Cancels and awaits the loop so a caller ending the session never
    /// races its own extraction against this one for the same session.
    func stopAutoCheckLoop() async {
        autoCheckTask?.cancel()
        await autoCheckTask?.value
        autoCheckTask = nil
    }

    private func performAutoCheck() async {
        guard route == nil else { return }
        guard let result = try? await client.promotionAutoCheck(sessionID: session.id) else { return }
        candidateCount = result.candidateCount
    }

    // MARK: Lifecycle

    func endSession() async -> Bool {
        guard session.session.isActive, !isEnding else { return false }
        isEnding = true
        defer { isEnding = false }
        await stopAutoCheckLoop()
        do {
            try await client.endSession(id: session.id)
            await loadStatus()
            return true
        } catch {
            notice = message(for: error)
            return false
        }
    }

    private func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func recovery(for error: any Error) -> RecoveryAction {
        (error as? RPCErrorDTO)?.recoveryAction ?? .retry
    }
}
