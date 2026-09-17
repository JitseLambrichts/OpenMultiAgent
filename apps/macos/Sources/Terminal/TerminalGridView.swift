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
    ///
    /// In de project-grid hebben cellen een gemengde status; gebruik dan
    /// `sessionActiveFor` voor een lookup per sessie-ID. Als die nil is,
    /// geldt `sessionActive` voor alle cellen (single-sessie detail).
    var sessionActive: Bool = true
    var sessionActiveFor: ((String) -> Bool)? = nil
    var titleFor: (String) -> String = { $0 }
    /// Wanneer gezet toont elke cel een "Open detail"-knop die naar de
    /// single-sessie detailview navigeert. Alleen gebruikt in de project-grid;
    /// het sessie-detail geeft nil door en verbergt de knop.
    var onOpenDetail: ((String) -> Void)? = nil
    /// In het single-sessie detail is sluiten van de enige koppeling
    /// betekenisloos (zou een lege picker-cel tonen); verberg dan de knop.
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
}

/// Single-sessie detailvariant zónder Grid. Het detail heeft per definitie
/// één bezette cel; die direct (zonder Grid) in de VStack leggen is het enige
/// meet-veilige patroon: de VStack geeft de header zijn ideale hoogte en de
/// cel vult de resterende ruimte. Een Grid-cel met ongelimiteerde hoogte kan
/// bij het meten ongelimiteerde hoogte naar boven rapporteren, waardoor de
/// VStack uitpuilt en de header (Terug-knop, tabs) buiten beeld verdwijnt —
/// precies de fullscreen-terminalval waarbij alleen de sidebar nog klikbaar
/// is. Zie `TerminalCellView`.
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
                // Bewust géén maxHeight:.infinity (zie endedSessionView in
                // SessionWorkspaceView): onder de AppKit-splitview van
                // `.inspector` explodeert elke gulzige hoogteclaim.
                ProgressView("Terminal verbinden…")
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

/// Eén terminalcel: header met status plus de terminal of de exited-status.
/// Gedeeld door de project-grid (in een Grid-cel) en het sessie-detail
/// (direct in de VStack via `SingleTerminalView`, zónder Grid).
struct TerminalCellView: View {
    let model: TerminalWorkspaceModel
    let controller: TerminalController
    let sessionID: String
    let isFocused: Bool
    var title: String
    var sessionActive: Bool
    /// Focus-toggle verbergen in het single-sessie detail: bij één cel is
    /// focussen betekenisloos.
    var allowFocus: Bool = true
    var allowClose: Bool = true
    /// Nil = geen "Open detail"-knop (sessie-detail); gezet in de project-grid.
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
        .accessibilityLabel("Terminal voor sessie \(sessionID)")
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
                StatusBadge(text: "Gekoppeld", symbol: "circle.fill", color: OMAColor.positive)
            case .exited:
                StatusBadge(text: "Gestopt", symbol: "bolt.slash", color: OMAColor.attention)
            case .idle:
                StatusBadge(text: "Niet gekoppeld", symbol: "circle", color: OMAColor.quiet)
            }
            Spacer(minLength: 4)
            if let onOpenDetail {
                Button("Open detail", systemImage: "arrow.up.forward", action: onOpenDetail)
                    .help("Open het sessie-detail (terminal, wijzigingen, geheugen, transcript)")
                    .modifier(CellControl())
            }
            if allowFocus {
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
            }
            if allowClose {
                Button("Sluit terminal", systemImage: "xmark") {
                    model.close(sessionID: sessionID)
                }
                .help("Sluit alleen deze koppeling; de sessie blijft draaien")
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
