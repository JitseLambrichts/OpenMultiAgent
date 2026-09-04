import AppKit
import SwiftTerm
import SwiftUI

/// Hosts the SwiftTerm view inside a container that is exactly the size SwiftUI
/// proposes. SwiftTerm sizes itself to whole rows and columns and may extend
/// past its slot; without the container, AppKit hit-testing would route clicks
/// meant for neighbouring controls into the terminal.
final class TerminalHostView: NSView {
    private let terminal: NSView

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        terminal.frame = bounds
        terminal.autoresizingMask = [.width, .height]
        addSubview(terminal)
        // The cell size comes from the grid, never from the terminal's row/column
        // count; otherwise six 80×24 terminals would overflow the window.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
            terminal.setContentHuggingPriority(.defaultLow, for: axis)
            terminal.setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        terminal.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }
}

struct TerminalRepresentable: NSViewRepresentable {
    let controller: TerminalController

    func makeNSView(context: Context) -> NSView {
        controller.startIfNeeded()
        guard let terminal = controller.terminalView?.view else { return NSView() }
        return TerminalHostView(terminal: terminal)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 200, height: proposal.height ?? 120)
    }
}
