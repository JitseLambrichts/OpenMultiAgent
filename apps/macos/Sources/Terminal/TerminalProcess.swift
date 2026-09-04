import AppKit
import SwiftTerm

enum TerminalAttachmentState: Equatable, Sendable {
    case idle
    case attached
    case exited(Int32?)
}

/// Abstracts the PTY so the workspace model and controller are testable
/// without SwiftTerm. Launch takes an executable plus argument array; there is
/// deliberately no API that accepts a shell string.
@MainActor
protocol TerminalProcessLaunching: AnyObject {
    var onExit: ((Int32?) -> Void)? { get set }
    func launch(_ attachment: TerminalAttachmentDTO)
    func terminate()
}

/// SwiftTerm-backed PTY. One instance per terminal controller; the view is
/// retained here so layout changes never recreate it.
@MainActor
final class SwiftTermProcess: NSObject, TerminalProcessLaunching, LocalProcessTerminalViewDelegate {
    let view: LocalProcessTerminalView
    var onExit: ((Int32?) -> Void)?

    override init() {
        view = LocalProcessTerminalView(frame: .zero)
        super.init()
        view.processDelegate = self
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        applyColors()
    }

    private func applyColors() {
        view.nativeBackgroundColor = NSColor(srgbRed: 11 / 255, green: 13 / 255, blue: 18 / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(white: 0.92, alpha: 1)
        view.caretColor = NSColor(srgbRed: 110 / 255, green: 139 / 255, blue: 255 / 255, alpha: 1)
    }

    func launch(_ attachment: TerminalAttachmentDTO) {
        view.startProcess(
            executable: attachment.executable,
            args: attachment.arguments,
            environment: nil,
            currentDirectory: attachment.cwd
        )
    }

    func terminate() {
        view.terminate()
    }

    // MARK: LocalProcessTerminalViewDelegate

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor in
            self.onExit?(exitCode)
        }
    }
}
