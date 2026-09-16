import SwiftUI

/// In-app settings home. Sections stack vertically so new settings can be
/// added as one more section view without changing navigation.
enum AppSettingsSection: String, CaseIterable, Identifiable {
    case agents
    case connection
    case about

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .connection: "Verbinding"
        case .about: "Over"
        }
    }

    var symbol: String {
        switch self {
        case .agents: "terminal"
        case .connection: "bolt.horizontal"
        case .about: "info.circle"
        }
    }
}

struct AppSettingsView: View {
    let app: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PageTitle(
                    title: "Instellingen",
                    subtitle: "Agents, verbinding en info op één plek."
                )
                .padding(.top, 28)

                ForEach(AppSettingsSection.allCases) { section in
                    sectionView(section)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(OMAColor.canvas)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Instellingen")
    }

    @ViewBuilder
    private func sectionView(_ section: AppSettingsSection) -> some View {
        switch section {
        case .agents:
            AgentsSettingsView(app: app)
        case .connection:
            SettingsConnectionSection(app: app)
        case .about:
            SettingsAboutSection()
        }
    }
}

/// Sidecar status, tmux health and the paths the app was launched with.
private struct SettingsConnectionSection: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Verbinding", symbol: "bolt.horizontal") {
                connectionBadge
            }
            VStack(alignment: .leading, spacing: 8) {
                row(title: "Status", value: statusText, symbol: statusSymbol, color: statusColor)
                row(
                    title: "tmux",
                    value: tmuxText,
                    symbol: tmuxAvailable ? "checkmark.circle" : "exclamationmark.triangle",
                    color: tmuxAvailable ? OMAColor.positive : OMAColor.attention
                )
                if let configuration = app.configuration {
                    row(
                        title: "Sidecar",
                        value: configuration.executableURL.path,
                        symbol: "app.terminal",
                        color: OMAColor.quiet
                    )
                    row(
                        title: "Werkmap",
                        value: configuration.workspaceRoot.path,
                        symbol: "folder",
                        color: OMAColor.quiet
                    )
                }
            }
            .padding(14)
            .omaCard()
        }
    }

    private var connectionBadge: some View {
        switch app.connection {
        case .connecting:
            StatusBadge(text: "Verbinden", symbol: "progress.indicator", color: OMAColor.quiet)
        case .ready:
            StatusBadge(text: "Verbonden", symbol: "checkmark.circle", color: OMAColor.positive)
        case .failed:
            StatusBadge(text: "Niet bereikbaar", symbol: "exclamationmark.triangle", color: OMAColor.attention)
        }
    }

    private var statusText: String {
        switch app.connection {
        case .connecting: "Verbinden met de service…"
        case .ready(let agents, _): "\(agents.count) agents beschikbaar"
        case .failed(let detail): detail
        }
    }

    private var statusSymbol: String {
        switch app.connection {
        case .connecting: "progress.indicator"
        case .ready: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private var statusColor: Color {
        switch app.connection {
        case .connecting: OMAColor.quiet
        case .ready: OMAColor.positive
        case .failed: OMAColor.attention
        }
    }

    private var tmuxAvailable: Bool {
        if case .ready(_, let available) = app.connection { return available }
        return false
    }

    private var tmuxText: String {
        tmuxAvailable ? "Beschikbaar" : "Niet gevonden — sessies blijven wel leesbaar"
    }

    private func row(title: String, value: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(value)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Static app info. Kept separate so future preferences get their own section.
private struct SettingsAboutSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Over", symbol: "info.circle")
            HStack(spacing: 12) {
                AccentDisc(symbol: "sparkle", size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("OpenMultiAgent")
                        .font(.body.weight(.semibold))
                    Text("Lokale multi-agent desktop. Donker thema, tmux-sessies, geheugen per project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .omaCard()
        }
    }
}
