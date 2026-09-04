import SwiftUI

struct ProjectCard: View {
    let project: ProjectDTO
    let onOpen: () -> Void
    let onNewSession: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(OMAColor.accent)
                    .frame(width: 38, height: 38)
                    .background(OMAColor.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(project.repoPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(OMAColor.quiet)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 12) {
                StatusBadge(text: "Geregistreerd", symbol: "checkmark.circle.fill", color: OMAColor.positive)
                Label(project.lastOpenedAt.formatted(.relative(presentation: .named)), systemImage: "clock")
                    .foregroundStyle(OMAColor.quiet)
                    .lineLimit(1)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Button("Open", action: onOpen)
                    .buttonStyle(.borderedProminent)
                    .tint(OMAColor.accent)
                    .accessibilityLabel("Open \(project.displayName)")
                Button("Nieuwe sessie", systemImage: "plus", action: onNewSession)
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Nieuwe sessie in \(project.displayName)")
                Spacer()
                Button("Verwijder", systemImage: "trash", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(OMAColor.quiet)
                    .help("Verwijder project uit het dashboard")
                    .accessibilityLabel("Verwijder \(project.displayName)")
            }
            .opacity(isHovering ? 1 : 0.78)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .omaCard(interactive: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            Button("Nieuwe sessie", action: onNewSession)
            Divider()
            Button("Verwijder uit dashboard", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(project.displayName)")
    }
}
