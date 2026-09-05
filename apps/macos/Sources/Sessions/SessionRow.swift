import SwiftUI

/// Actions a session row can trigger. The row itself has no sidecar access.
struct SessionRowActions {
    var open: () -> Void
    var resume: (() -> Void)?
    var switchAgent: (() -> Void)?
    var end: (() -> Void)?
    var remove: (() -> Void)?
}

struct SessionRow: View {
    let view: SessionViewDTO
    let actions: SessionRowActions
    var agentSymbol: String? = nil
    @State private var isHovering = false

    init(view: SessionViewDTO, agentSymbol: String? = nil, onOpen: @escaping () -> Void) {
        self.view = view
        self.actions = SessionRowActions(open: onOpen)
        self.agentSymbol = agentSymbol
    }

    init(view: SessionViewDTO, actions: SessionRowActions, agentSymbol: String? = nil) {
        self.view = view
        self.actions = actions
        self.agentSymbol = agentSymbol
    }

    private var agent: AgentKind? { view.currentAgent }

    private var resolvedSymbol: String {
        agentSymbol ?? agent?.symbol ?? "terminal"
    }

    private var status: (text: String, symbol: String, color: Color) {
        if view.session.isActive && view.tmuxAlive {
            ("Actief", "circle.fill", OMAColor.positive)
        } else if view.session.isActive {
            ("Geen tmux", "exclamationmark.circle", OMAColor.attention)
        } else {
            ("Afgerond", "checkmark.circle", OMAColor.quiet)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: actions.open) {
                HStack(spacing: 12) {
                    Image(systemName: resolvedSymbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(agent?.tint ?? .secondary)
                        .frame(width: 30, height: 30)
                        .background(OMAColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(view.session.displayTitle)
                            .font(.headline)
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            Text(agent?.title ?? "Geen agent")
                            if let branch = view.session.branch {
                                Text(branch).font(.caption.monospaced())
                            }
                            if view.session.usesWorktree {
                                Label("Worktree", systemImage: "arrow.triangle.branch")
                                    .labelStyle(.titleAndIcon)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        StatusBadge(text: status.text, symbol: status.symbol, color: status.color)
                        Text(view.session.startedAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Open sessie")
            .accessibilityLabel("Open sessie \(view.session.displayTitle), \(status.text)")

            if let remove = actions.remove {
                Button("Verwijder sessie", systemImage: "trash", role: .destructive, action: remove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(isHovering ? OMAColor.negative : OMAColor.quiet)
                    .help("Verwijder sessie")
                    .accessibilityLabel("Verwijder sessie \(view.session.displayTitle)")
                    .padding(.trailing, 12)
            }
        }
        .background(OMAColor.elevated.opacity(0.66), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: actions.open)
            if let resume = actions.resume, !view.session.isActive {
                Button("Hervat", systemImage: "play", action: resume)
            }
            if let switchAgent = actions.switchAgent {
                Button("Wissel agent…", systemImage: "arrow.left.arrow.right", action: switchAgent)
            }
            Divider()
            if let end = actions.end, view.session.isActive {
                Button("Beëindig sessie…", systemImage: "stop.circle", action: end)
            }
            if let remove = actions.remove {
                Button("Verwijder sessie…", systemImage: "trash", role: .destructive, action: remove)
            }
        }
    }
}
