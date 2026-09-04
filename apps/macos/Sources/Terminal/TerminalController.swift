import Foundation
import Observation

/// Owns one PTY attachment to a tmux session. Closing it ends only the local
/// attachment; the OMA session and its tmux server are untouched.
@MainActor
@Observable
final class TerminalController: TerminalControlling {
    let sessionID: String
    private(set) var state: TerminalAttachmentState = .idle
    private(set) var attachment: TerminalAttachmentDTO
    @ObservationIgnored let process: any TerminalProcessLaunching

    init(sessionID: String, attachment: TerminalAttachmentDTO, process: any TerminalProcessLaunching) {
        self.sessionID = sessionID
        self.attachment = attachment
        self.process = process
        process.onExit = { [weak self] code in
            self?.state = .exited(code)
        }
    }

    var terminalView: SwiftTermProcess? { process as? SwiftTermProcess }

    func startIfNeeded() {
        guard state != .attached else { return }
        state = .attached
        process.launch(attachment)
    }

    /// Re-attaches after the PTY exited (for example `tmux detach`). Uses a
    /// fresh attachment when provided so a moved tmux binary is picked up.
    func reconnect(with fresh: TerminalAttachmentDTO? = nil) {
        if let fresh { attachment = fresh }
        state = .attached
        process.launch(attachment)
    }

    func close() {
        DebugTrace.log("controller close \(sessionID) state=\(state)")
        guard state == .attached else { return }
        process.terminate()
        state = .idle
    }
}

@MainActor
struct SidecarTerminalFactory: TerminalControllerFactory {
    let client: any DesktopAPI

    func makeController(sessionID: String) async throws -> any TerminalControlling {
        let attachment = try await client.terminalAttachment(sessionID: sessionID)
        return TerminalController(sessionID: sessionID, attachment: attachment, process: SwiftTermProcess())
    }

    func freshAttachment(sessionID: String) async throws -> TerminalAttachmentDTO {
        try await client.terminalAttachment(sessionID: sessionID)
    }
}
