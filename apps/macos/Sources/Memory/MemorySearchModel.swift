import Foundation
import Observation

/// Debounced memory search. Each keystroke cancels the previous request so the
/// sidecar only sees the query the user settled on.
@MainActor
@Observable
final class MemorySearchModel {
    @ObservationIgnored private let client: any DesktopAPI
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored let debounce: Duration

    var repoPath: String? {
        didSet { if repoPath != oldValue { scheduleSearch() } }
    }
    private(set) var query = ""
    private(set) var hits: [SearchHitDTO] = []
    private(set) var recent: [MemoryDTO] = []
    private(set) var isSearching = false
    private(set) var notice: String?
    /// The queries that actually reached the sidecar, newest last.
    private(set) var executedQueries: [String] = []

    init(client: any DesktopAPI, repoPath: String? = nil, debounce: Duration = .milliseconds(250)) {
        self.client = client
        self.repoPath = repoPath
        self.debounce = debounce
    }

    func loadRecent() async {
        do {
            recent = try await client.listMemory(repoPath: repoPath, limit: 25)
            notice = nil
        } catch {
            notice = userMessage(for: error)
        }
    }

    func updateQuery(_ value: String) {
        guard value != query else { return }
        query = value
        scheduleSearch()
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            hits = []
            isSearching = false
            return
        }
        isSearching = true
        searchTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.search(trimmed)
        }
    }

    func search(_ text: String) async {
        do {
            executedQueries.append(text)
            let results = try await client.searchMemory(query: text, repoPath: repoPath, limit: 25)
            guard !Task.isCancelled, text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            hits = results
            notice = nil
        } catch is CancellationError {
            return
        } catch {
            notice = userMessage(for: error)
        }
        isSearching = false
    }

    private func userMessage(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
