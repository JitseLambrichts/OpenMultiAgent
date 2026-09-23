import Foundation
import Observation

enum TerminalLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case single
    case horizontal
    case twoByTwo
    case adaptive

    var id: Self { self }

    var capacity: Int {
        switch self {
        case .single: 1
        case .horizontal: 2
        case .twoByTwo: 4
        case .adaptive: 6
        }
    }

    var columns: Int {
        switch self {
        case .single: 1
        case .horizontal, .twoByTwo, .adaptive: 2
        }
    }

    var title: String {
        switch self {
        case .single: "Single"
        case .horizontal: "Split"
        case .twoByTwo: "2 × 2"
        case .adaptive: "Up to six"
        }
    }

    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .horizontal: "rectangle.split.2x1"
        case .twoByTwo: "rectangle.split.2x2"
        case .adaptive: "rectangle.split.3x3"
        }
    }

    static func fitting(_ count: Int) -> TerminalLayout {
        switch count {
        case ...1: .single
        case 2: .horizontal
        case 3...4: .twoByTwo
        default: .adaptive
        }
    }
}

struct TerminalCell: Identifiable, Equatable, Sendable {
    let id: UUID
    var sessionID: String?

    init(id: UUID = UUID(), sessionID: String? = nil) {
        self.id = id
        self.sessionID = sessionID
    }

    var isOccupied: Bool { sessionID != nil }
}

@MainActor
protocol TerminalControlling: AnyObject {
    var sessionID: String { get }
    var state: TerminalAttachmentState { get }
    func startIfNeeded()
    func reconnect(with fresh: TerminalAttachmentDTO?)
    func close()
}

@MainActor
protocol TerminalControllerFactory {
    func makeController(sessionID: String) async throws -> any TerminalControlling
    func freshAttachment(sessionID: String) async throws -> TerminalAttachmentDTO
}

extension TerminalControllerFactory {
    func freshAttachment(sessionID: String) async throws -> TerminalAttachmentDTO {
        throw SidecarClientError.unavailable("No new terminal attachment is available.")
    }
}

/// Owns the ordered cell assignments plus one controller per session UUID.
/// Layout changes rearrange the same controllers; they are never recreated.
@MainActor
@Observable
final class TerminalWorkspaceModel {
    static let maximumCells = 6

    @ObservationIgnored private let factory: any TerminalControllerFactory
    private var controllers: [String: any TerminalControlling] = [:]

    private(set) var cells: [TerminalCell] = [TerminalCell()]
    private(set) var layout: TerminalLayout = .single
    private(set) var pendingLayoutConfirmation: TerminalLayout?
    private(set) var focusedSessionID: String?
    private(set) var errorMessage: String?
    private var layoutBeforeFocus: TerminalLayout?

    init(factory: any TerminalControllerFactory) {
        self.factory = factory
    }

    var occupiedSessionIDs: [String] { cells.compactMap(\.sessionID) }
    var canOpenMore: Bool { occupiedSessionIDs.count < Self.maximumCells }

    func controller(for sessionID: String) -> (any TerminalControlling)? {
        controllers[sessionID]
    }

    func isOpen(_ sessionID: String) -> Bool {
        controllers[sessionID] != nil
    }

    // MARK: Opening and closing

    func open(sessionID: String) async throws {
        if controllers[sessionID] != nil {
            return
        }
        guard canOpenMore else { return }

        let controller = try await factory.makeController(sessionID: sessionID)
        controllers[sessionID] = controller
        if let emptyIndex = cells.firstIndex(where: { $0.sessionID == nil }) {
            cells[emptyIndex].sessionID = sessionID
        } else {
            cells.append(TerminalCell(sessionID: sessionID))
        }
        if cells.count > layout.capacity {
            layout = TerminalLayout.fitting(cells.count)
        }
        errorMessage = nil
    }

    /// Opens a session into a specific cell (the picker path). Falls back to the
    /// first empty cell when the target is already occupied by another session.
    func open(sessionID: String, into cellID: UUID) async throws {
        guard controllers[sessionID] == nil else { return }
        guard canOpenMore else { return }
        let controller = try await factory.makeController(sessionID: sessionID)
        controllers[sessionID] = controller
        if let index = cells.firstIndex(where: { $0.id == cellID }), cells[index].sessionID == nil {
            cells[index].sessionID = sessionID
        } else if let emptyIndex = cells.firstIndex(where: { $0.sessionID == nil }) {
            cells[emptyIndex].sessionID = sessionID
        } else {
            cells.append(TerminalCell(sessionID: sessionID))
            layout = TerminalLayout.fitting(cells.count)
        }
        errorMessage = nil
    }

    func openReportingError(sessionID: String) async {
        do {
            try await open(sessionID: sessionID)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Ends only the local PTY attachment. The OMA session keeps running.
    func close(sessionID: String) {
        DebugTrace.log("terminal close requested \(sessionID) known=\(controllers[sessionID] != nil)")
        controllers.removeValue(forKey: sessionID)?.close()
        if let index = cells.firstIndex(where: { $0.sessionID == sessionID }) {
            cells[index].sessionID = nil
        }
        if focusedSessionID == sessionID {
            unfocus()
        }
    }

    func reconnect(sessionID: String) async {
        guard let controller = controllers[sessionID] else { return }
        let fresh = try? await factory.freshAttachment(sessionID: sessionID)
        controller.reconnect(with: fresh)
    }

    // MARK: Focus

    func focus(sessionID: String) {
        DebugTrace.log("terminal focus requested \(sessionID)")
        guard controllers[sessionID] != nil else { return }
        if focusedSessionID == nil {
            layoutBeforeFocus = layout
        }
        focusedSessionID = sessionID
    }

    func unfocus() {
        focusedSessionID = nil
        if let previous = layoutBeforeFocus {
            layout = previous
            layoutBeforeFocus = nil
        }
    }

    // MARK: Layout

    func requestLayout(_ requested: TerminalLayout) {
        if focusedSessionID != nil {
            layoutBeforeFocus = requested
            return
        }
        guard occupiedSessionIDs.count <= requested.capacity else {
            pendingLayoutConfirmation = requested
            return
        }
        pendingLayoutConfirmation = nil
        applyLayout(requested)
    }

    /// Completes a shrink after the user chose which attachments to close.
    func confirmPendingLayout(closing sessionIDs: [String]) {
        guard let requested = pendingLayoutConfirmation else { return }
        for sessionID in sessionIDs {
            close(sessionID: sessionID)
        }
        guard occupiedSessionIDs.count <= requested.capacity else { return }
        pendingLayoutConfirmation = nil
        applyLayout(requested)
    }

    func cancelPendingLayout() {
        pendingLayoutConfirmation = nil
    }

    private func applyLayout(_ requested: TerminalLayout) {
        layout = requested
        let occupied = cells.filter(\.isOccupied)
        var arranged = occupied
        while arranged.count < requested.capacity {
            arranged.append(TerminalCell())
        }
        cells = arranged
    }
}
