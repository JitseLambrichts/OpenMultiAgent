import AppKit
import SwiftUI

/// Shown when the sidecar cannot launch or complete its handshake. Existing
/// terminal attachments are unaffected, which the copy makes explicit.
struct RecoveryView: View {
    let detail: String
    let configuration: SidecarConfiguration?
    let onReconnect: () -> Void
    let onChooseCheckout: (URL) -> Void

    @State private var showsDetails = false

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()
            VStack(spacing: 20) {
                AccentDisc(symbol: "bolt.horizontal", size: 64, tint: OMAColor.attention)

                VStack(spacing: 6) {
                    Text("De OpenMultiAgent-service is niet bereikbaar")
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text("Lopende tmux-sessies blijven gewoon draaien. Verbind opnieuw om projecten en sessies te laden.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button("Verbind opnieuw", systemImage: "arrow.clockwise", action: onReconnect)
                        .buttonStyle(.omaPrimary)
                        .keyboardShortcut(.defaultAction)
                    if configuration?.source == .development {
                        Button("Kies OMA-checkout…", systemImage: "folder", action: chooseCheckout)
                            .buttonStyle(.omaSecondary)
                            .help("Kies de map met de OpenMultiAgent-broncode")
                    }
                }

                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let configuration {
                            Text("\(configuration.executableURL.path) \(configuration.arguments.joined(separator: " "))")
                            Text(configuration.workspaceRoot.path)
                        }
                        Text(detail)
                    }
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
                .frame(maxWidth: 520)
            }
            .padding(32)
            .frame(maxWidth: 560)
            .omaCard()
            .padding(40)
        }
    }

    private func chooseCheckout() {
        let panel = NSOpenPanel()
        panel.title = "Kies de OpenMultiAgent-checkout"
        panel.message = "Kies de map met package.json en packages/desktop-api."
        panel.prompt = "Gebruik"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChooseCheckout(url)
    }
}
