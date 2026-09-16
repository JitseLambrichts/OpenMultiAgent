import SwiftUI

/// Renders the cell arrangement. Terminals are hosted in a non-lazy grid so
/// cells are never recycled while attached. Live output is never animated.
///
/// Cell controls live in a header *above* the terminal rather than in an
/// overlay: AppKit hit-testing hands clicks to the hosted SwiftTerm NSView,
/// so SwiftUI controls layered on top of it would never receive them.
struct TerminalGridView: View {
    let model: TerminalWorkspaceModel
    /// Of de bijbehorende OMA-sessie nog actief is. Na beëindigen is de
    /// tmux-koppeling weg én de sessie klaar; dan tonen we geen
    /// "Verbind opnieuw" meer voor een dode tmux-sessie.
    var sessionActive: Bool = true
    var titleFor: (String) -> String = { $0 }
    let onPickSession: (UUID) -> Void

    var body: some View {
        Group {
            if let focused = model.focusedSessionID,
               let controller = model.controller(for: focused) as? TerminalController {
                terminalCell(controller, sessionID: focused, isFocused: true)
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
            terminalCell(controller, sessionID: sessionID, isFocused: false)
        } else {
            Button {
                onPickSession(cell.id)
            } label: {
                ContentUnavailableView {
                    Label("Lege terminal", systemImage: "plus.rectangle.on.rectangle")
                } description: {
                    Text("Kies een sessie van dit project om hier te openen.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityLabel("Open een sessie in deze lege terminal")
        }
    }

    private func terminalCell(_ controller: TerminalController, sessionID: String, isFocused: Bool) -> some View {
        VStack(spacing: 0) {
            cellHeader(controller: controller, sessionID: sessionID, isFocused: isFocused)
            Divider()
            if case .exited(let code) = controller.state {
                exitedView(sessionID: sessionID, code: code)
            } else {
                TerminalRepresentable(controller: controller)
            }
        }
        .background(OMAColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal voor sessie \(sessionID)")
    }

    private func cellHeader(controller: TerminalController, sessionID: String, isFocused: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(titleFor(sessionID))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            switch controller.state {
            case .attached:
                StatusBadge(text: "Gekoppeld", symbol: "circle.fill", color: OMAColor.positive)
            case .exited:
                StatusBadge(text: "Gestopt", symbol: "bolt.slash", color: OMAColor.attention)
            case .idle:
                StatusBadge(text: "Niet gekoppeld", symbol: "circle", color: OMAColor.quiet)
            }
            Spacer(minLength: 4)
            if isFocused {
                Button("Verlaat focus", systemImage: "arrow.down.right.and.arrow.up.left") {
                    model.unfocus()
                }
                .help("Terug naar de rasterindeling")
                .modifier(CellControl())
            } else {
                Button("Focus", systemImage: "arrow.up.left.and.arrow.down.right") {
                    model.focus(sessionID: sessionID)
                }
                .help("Toon alleen deze terminal")
                .modifier(CellControl())
            }
            Button("Sluit terminal", systemImage: "xmark") {
                model.close(sessionID: sessionID)
            }
            .help("Sluit alleen deze koppeling; de sessie blijft draaien")
            .modifier(CellControl())
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

    private func exitedView(sessionID: String, code: Int32?) -> some View {
        VStack(spacing: 12) {
            Label(sessionActive ? "Terminalkoppeling gestopt" : "Sessie beëindigd", systemImage: sessionActive ? "bolt.slash" : "checkmark.circle")
                .font(.headline)
            Text(exitedMessage(code: code))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if sessionActive {
                Button("Verbind opnieuw", systemImage: "arrow.clockwise") {
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
            return "De tmux-sessie is gestopt en de sessie staat op Afgerond. Het transcript, de worktree (na merge in de hoofdcheckout) en het geheugen blijven bewaard."
        }
        return code.map { "De tmux-koppeling eindigde met code \($0). De sessie zelf is niet beëindigd." }
            ?? "De tmux-koppeling is verbroken. De sessie zelf is niet beëindigd."
    }
}
