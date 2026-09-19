import SwiftUI

struct FileTreeView: View {
    let nodes: [FileNode]
    let selectedPath: String?
    let onOpen: (String) -> Void

    var body: some View {
        List(selection: Binding(
            get: { selectedPath },
            set: { path in
                if let path, !path.isEmpty { onOpen(path) }
            }
        )) {
            OutlineGroup(nodes, id: \.path, children: \.children) { node in
                Label(node.name, systemImage: node.isDirectory ? "folder" : "doc.text")
                    .font(node.isDirectory ? .subheadline.weight(.medium) : .subheadline.monospaced())
                    .lineLimit(1)
                    .tag(node.isDirectory ? "" : node.path)
                    .accessibilityLabel(node.path)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(OMAColor.canvas)
    }
}