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
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OMAColor.accent)
                    .frame(width: 34, height: 34)
                    .background(OMAColor.elevated, in: Circle())
                    .accessibilityHidden(true)
            }

            HStack(spacing: 12) {
                StatusBadge(text: "Registered", symbol: "checkmark.circle.fill", color: OMAColor.positive)
                Label(project.lastOpenedAt.formatted(.relative(presentation: .named)), systemImage: "clock")
                    .foregroundStyle(OMAColor.quiet)
                    .lineLimit(1)
                    .font(.caption)
            }

            HStack(spacing: 8) {
                Button("Open", action: onOpen)
                    .buttonStyle(.omaPrimary)
                    .accessibilityLabel("Open \(project.displayName)")
                Button("New Session", systemImage: "plus", action: onNewSession)
                    .buttonStyle(.omaSecondary)
                    .accessibilityLabel("New Session in \(project.displayName)")
                Spacer()
                Button("Delete", systemImage: "trash", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(OMAColor.quiet)
                    .help("Remove project from the dashboard")
                    .accessibilityLabel("Delete \(project.displayName)")
            }
            .opacity(isHovering ? 1 : 0.85)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 184, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .omaCard(interactive: isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open", action: onOpen)
            Button("New Session", action: onNewSession)
            Divider()
            Button("Remove from Dashboard", role: .destructive, action: onRemove)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project \(project.displayName)")
    }
}
