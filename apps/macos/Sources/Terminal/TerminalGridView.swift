import SwiftUI

/// Renders the cell arrangement. Terminals are hosted in a non-lazy grid so
/// cells are never recycled while attached. Live output is never animated.
///
/// Cell controls live in a header *above* the terminal rather than in an
/// overlay: AppKit hit-testing hands clicks to the hosted SwiftTerm NSView,
/// so SwiftUI controls layered on top of it would never receive them.
struct TerminalGridView: View {
    let model: TerminalWorkspaceModel
    /// Whether the matching OMA session is still active. After ending, the
    /// tmux attachment is gone and the session is complete; then we no longer
    /// show "Reconnect" for a dead tmux session.
    ///
    /// In the project grid cells have mixed status; use
    /// `sessionActiveFor` for a per-session-ID lookup. If that is nil,
    /// `sessionActive` applies to every cell (single-session detail).
    var sessionActive: Bool = true
    var sessionActiveFor: ((String) -> Bool)? = nil
    var titleFor: (String) -> String = { $0 }
    /// When set, each cell shows an "Open Detail" button that navigates to the
    /// single-session detail view. Only used in the project grid;
    /// session detail passes nil and hides the button.
    var onOpenDetail: ((String) -> Void)? = nil
    /// In single-session detail, closing the only attachment is
    /// meaningless (it would show an empty picker cell); hide the button then.
    var allowClose: Bool = true
    let onPickSession: (UUID) -> Void

    private func isActive(_ sessionID: String) -> Bool {
        sessionActiveFor?(sessionID) ?? sessionActive
    }

    var body: some View {
        Group {
            if let focused = model.focusedSessionID,
               let controller = model.controller(for: focused) as? TerminalController {
                TerminalCellView(
                    model: model,
                    controller: controller,
                    sessionID: focused,
                    isFocused: true,
                    title: titleFor(focused),
                    sessionActive: isActive(focused),
                    allowClose: allowClose,
                    onOpenDetail: onOpenDetail.map { callback in { callback(focused) } }
                )
            } else {
                Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(rows, id: \.first?.id) { row in
                        GridRow {
                            ForEach(row) { cell in
                                cellView(cell)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(OMAColor.canvas)
        .clipped()
        .transaction { $0.animation = nil }
    }

    private var rows: [[TerminalCell]] {
        let columns = max(model.layout.columns, 1)
        return stride(from: 0, to: model.cells.count, by: columns).map {
            Array(model.cells[$0..<min($0 + columns, model.cells.count)])
        }
    }

    @ViewBuilder
    private func cellView(_ cell: TerminalCell) -> some View {
        if let sessionID = cell.sessionID,
           let controller = model.controller(for: sessionID) as? TerminalController {
            TerminalCellView(
                model: model,
                controller: controller,
                sessionID: sessionID,
                isFocused: false,
                title: titleFor(sessionID),
                sessionActive: isActive(sessionID),
                allowClose: allowClose,
                onOpenDetail: onOpenDetail.map { callback in { callback(sessionID) } }
            )
        } else {
            Button {
                onPickSession(cell.id)
            } label: {
                ContentUnavailableView {
                    Label("Empty terminal", systemImage: "plus.rectangle.on.rectangle")
                } description: {
                    Text("Choose a session from this project to open here.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Open a session in this empty terminal")
        }
    }
}

/// Single-session detail variant without a Grid. Detail has exactly
/// one occupied cell; placing it directly (without a Grid) in the VStack is the
/// only measurement-safe pattern: the VStack gives the header its ideal height
/// and the cell fills the rest. A Grid cell with unbounded height can
/// report unbounded height upward during measurement, so the
/// VStack overflows and the header (Back button, tabs) disappears —
/// exactly the fullscreen-terminal trap where only the sidebar remains clickable.
/// See `TerminalCellView`.
struct SingleTerminalView: View {
    let model: TerminalWorkspaceModel
    let sessionID: String
    var title: String
    var sessionActive: Bool

    var body: some View {
        Group {
            if let controller = model.controller(for: sessionID) as? TerminalController {
                TerminalCellView(
                    model: model,
                    controller: controller,
                    sessionID: sessionID,
                    isFocused: false,
                    title: title,
                    sessionActive: sessionActive,
                    allowFocus: false,
                    allowClose: false,
                    onOpenDetail: nil
                )
            } else {
                // Intentionally no maxHeight:.infinity (see endedSessionView in
                // SessionWorkspaceView): under the AppKit split view of
                // `.inspector` every greedy height claim explodes.
                ProgressView("Connecting terminal…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.bottom, 20)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(OMAColor.canvas)
        .clipped()
    }
}

/// One terminal cell: header with status plus the terminal or the exited status.
/// Shared by the project grid (in a Grid cell) and session detail
/// (directly in the VStack via `SingleTerminalView`, without a Grid).
struct TerminalCellView: View {
    let model: TerminalWorkspaceModel
    let controller: TerminalController
    let sessionID: String
    let isFocused: Bool
    var title: String
    var sessionActive: Bool
    /// Hide the focus toggle in single-session detail: with one cell,
    /// focusing is meaningless.
    var allowFocus: Bool = true
    var allowClose: Bool = true
    /// Nil = no "Open Detail" button (session detail); set in the project grid.
    var onOpenDetail: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            cellHeader
            Divider()
            if case .exited(let code) = controller.state {
                exitedView(code: code)
            } else {
                TerminalRepresentable(controller: controller)
            }
        }
        .background(OMAColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .clipped()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal for session \(sessionID)")
    }

    private var cellHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            switch controller.state {
            case .attached:
                StatusBadge(text: "Attached", symbol: "circle.fill", color: OMAColor.positive)
            case .exited:
                StatusBadge(text: "Stopped", symbol: "bolt.slash", color: OMAColor.attention)
            case .idle:
                StatusBadge(text: "Not attached", symbol: "circle", color: OMAColor.quiet)
            }
            Spacer(minLength: 4)
            if let onOpenDetail {
                Button("Open Detail", systemImage: "arrow.up.forward", action: onOpenDetail)
                    .help("Open the session detail (terminal, changes, memory, transcript)")
                    .modifier(CellControl())
            }
            if allowFocus {
                if isFocused {
                    Button("Exit Focus", systemImage: "arrow.down.right.and.arrow.up.left") {
                        model.unfocus()
                    }
                    .help("Return to the grid layout")
                    .modifier(CellControl())
                } else {
                    Button("Focus", systemImage: "arrow.up.left.and.arrow.down.right") {
                        model.focus(sessionID: sessionID)
                    }
                    .help("Show only this terminal")
                    .modifier(CellControl())
                }
            }
            if allowClose {
                Button("Close Terminal", systemImage: "xmark") {
                    model.close(sessionID: sessionID)
                }
                .help("Close only this attachment; the session keeps running")
                .modifier(CellControl())
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(OMAColor.elevated)
    }

    /// Icon-only controls get a comfortable, consistent hit target.
    private struct CellControl: ViewModifier {
        func body(content: Content) -> some View {
            content
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
    }

    private func exitedView(code: Int32?) -> some View {
        VStack(spacing: 12) {
            Label(sessionActive ? "Terminal attachment stopped" : "Session ended", systemImage: sessionActive ? "bolt.slash" : "checkmark.circle")
                .font(.headline)
            Text(exitedMessage(code: code))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if sessionActive {
                Button("Reconnect", systemImage: "arrow.clockwise") {
                    Task { await model.reconnect(sessionID: sessionID) }
                }
                .buttonStyle(.omaPrimary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exitedMessage(code: Int32?) -> String {
        guard sessionActive else {
            return "The tmux session has stopped and this session is complete. The transcript, worktree (after merging into the main checkout), and memory are kept."
        }
        return code.map { "The tmux attachment ended with code \($0). The session itself was not ended." }
            ?? "The tmux attachment was lost. The session itself was not ended."
    }
}
