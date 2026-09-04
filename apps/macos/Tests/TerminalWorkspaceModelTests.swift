import Testing
@testable import OpenMultiAgent

@MainActor
struct TerminalWorkspaceModelTests {
    @Test func changingLayoutPreservesControllers() async throws {
        let model = TerminalWorkspaceModel(factory: RecordingTerminalFactory())

        try await model.open(sessionID: "session-a")
        let original = model.controller(for: "session-a")
        model.requestLayout(.twoByTwo)

        #expect(model.controller(for: "session-a") === original)
        #expect(model.cells.count == 4)
        #expect(model.cells.first?.sessionID == "session-a")
    }

    @Test func shrinkingNeverDropsAnOccupiedCell() async throws {
        let model = TerminalWorkspaceModel(factory: RecordingTerminalFactory())
        for index in 0..<4 {
            try await model.open(sessionID: "session-\(index)")
        }

        model.requestLayout(.single)

        #expect(model.pendingLayoutConfirmation == .single)
        #expect(model.layout == .twoByTwo)
        #expect(model.occupiedSessionIDs.count == 4)
    }

    @Test func confirmingShrinkClosesOnlyChosenAttachments() async throws {
        let factory = RecordingTerminalFactory()
        let model = TerminalWorkspaceModel(factory: factory)
        for index in 0..<3 {
            try await model.open(sessionID: "session-\(index)")
            model.controller(for: "session-\(index)")?.startIfNeeded()
        }
        model.requestLayout(.horizontal)

        model.confirmPendingLayout(closing: ["session-2"])

        #expect(model.pendingLayoutConfirmation == nil)
        #expect(model.layout == .horizontal)
        #expect(model.occupiedSessionIDs == ["session-0", "session-1"])
        #expect(factory.processes["session-2"]?.terminated == true)
        #expect(factory.processes["session-0"]?.terminated == false)
    }

    @Test func oneSessionCannotOccupyTwoCells() async throws {
        let model = TerminalWorkspaceModel(factory: RecordingTerminalFactory())
        try await model.open(sessionID: "session-a")
        try await model.open(sessionID: "session-a")
        model.requestLayout(.horizontal)
        try await model.open(sessionID: "session-a", into: model.cells[1].id)

        #expect(model.occupiedSessionIDs == ["session-a"])
    }

    @Test func focusIsPresentationStateAndRestoresThePreviousLayout() async throws {
        let model = TerminalWorkspaceModel(factory: RecordingTerminalFactory())
        try await model.open(sessionID: "session-a")
        try await model.open(sessionID: "session-b")
        #expect(model.layout == .horizontal)
        let controller = model.controller(for: "session-b")

        model.focus(sessionID: "session-b")
        #expect(model.focusedSessionID == "session-b")
        #expect(model.controller(for: "session-b") === controller)

        model.unfocus()
        #expect(model.focusedSessionID == nil)
        #expect(model.layout == .horizontal)
        #expect(model.occupiedSessionIDs == ["session-a", "session-b"])
    }

    @Test func closingEndsOnlyTheLocalAttachmentAndReconnectKeepsIdentity() async throws {
        let factory = RecordingTerminalFactory()
        let model = TerminalWorkspaceModel(factory: factory)
        try await model.open(sessionID: "session-a")
        let controller = try #require(model.controller(for: "session-a"))
        controller.startIfNeeded()
        #expect(controller.state == .attached)

        factory.processes["session-a"]?.onExit?(1)
        #expect(controller.state == .exited(1))

        await model.reconnect(sessionID: "session-a")
        #expect(model.controller(for: "session-a") === controller)
        #expect(controller.state == .attached)
        #expect(factory.processes["session-a"]?.launches == 2)

        model.close(sessionID: "session-a")
        #expect(model.controller(for: "session-a") == nil)
        #expect(factory.processes["session-a"]?.terminated == true)
        #expect(factory.attachmentRequests == 2)
    }

    @Test func capacityIsSixControllers() async throws {
        let model = TerminalWorkspaceModel(factory: RecordingTerminalFactory())
        for index in 0..<8 {
            try await model.open(sessionID: "session-\(index)")
        }
        #expect(model.occupiedSessionIDs.count == 6)
        #expect(model.layout == .adaptive)
        #expect(model.canOpenMore == false)
    }
}

@MainActor
private final class RecordingProcess: TerminalProcessLaunching {
    var onExit: ((Int32?) -> Void)?
    var launches = 0
    var terminated = false

    func launch(_ attachment: TerminalAttachmentDTO) {
        launches += 1
        terminated = false
    }

    func terminate() {
        terminated = true
    }
}

@MainActor
private final class RecordingTerminalFactory: TerminalControllerFactory {
    var processes: [String: RecordingProcess] = [:]
    var attachmentRequests = 0

    private var attachment: TerminalAttachmentDTO {
        TerminalAttachmentDTO(executable: "/opt/homebrew/bin/tmux", arguments: ["attach", "-t", "oma-x"], cwd: "/repo")
    }

    func makeController(sessionID: String) async throws -> any TerminalControlling {
        attachmentRequests += 1
        let process = RecordingProcess()
        processes[sessionID] = process
        return TerminalController(sessionID: sessionID, attachment: attachment, process: process)
    }

    func freshAttachment(sessionID: String) async throws -> TerminalAttachmentDTO {
        attachmentRequests += 1
        return attachment
    }
}
