import AppKit
import SwiftUI

/// Generated documentation grouped by project. Files live in the repository;
/// the app only lists them and opens them with the user's default editor.
struct LivingDocsView: View {
    let model: AppModel
    @State private var docsByProject: [String: [LivingDocDTO]] = [:]
    @State private var notice: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        PageTitle(title: "Living Docs", subtitle: "Markdown onder .oma/docs, per project, gegenereerd uit gepromoveerde kennis.")
                        Spacer()
                        Button("Vernieuw", systemImage: "arrow.clockwise") { Task { await load() } }
                            .buttonStyle(.omaIcon)
                            .help("Vernieuw documentatie")
                            .symbolEffect(.rotate, isActive: isLoading)
                    }
                    if let notice {
                        InlineNotice(notice, actionTitle: "Opnieuw") { Task { await load() } }
                    }
                    if model.projects.projects.isEmpty {
                        ContentUnavailableView {
                            Label("Nog geen projecten", systemImage: "doc.text")
                        } description: {
                            Text("Voeg een project toe en promoveer kennis om hier documentatie te zien.")
                        }
                    } else {
                        ForEach(model.projects.projects) { project in
                            projectSection(project)
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 28)
            }
        }
        .task { await load() }
        .onChange(of: model.reconciliationTick) { _, _ in Task { await load() } }
    }

    private func projectSection(_ project: ProjectDTO) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            PanelHeader(project.displayName, symbol: "shippingbox") {
                Text(project.repoPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            let docs = docsByProject[project.id] ?? []
            if docs.isEmpty {
                Text("Nog geen documentatie. Promoveer kennis vanuit een afgeronde sessie.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(docs) { doc in
                    LivingDocRow(doc: doc, repoPath: project.repoPath)
                }
            }
        }
        .padding(20)
        .omaCard()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        var result: [String: [LivingDocDTO]] = [:]
        var failure: String?
        for project in model.projects.projects {
            do {
                result[project.id] = try await model.client.listDocs(repoPath: project.repoPath)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        docsByProject = result
        notice = failure
    }
}

struct LivingDocRow: View {
    let doc: LivingDocDTO
    let repoPath: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: doc.kind.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(OMAColor.accent)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).font(.body.weight(.medium))
                Text(doc.path).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(doc.modifiedAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open", systemImage: "arrow.up.forward.square") {
                NSWorkspace.shared.open(URL(fileURLWithPath: repoPath).appending(path: doc.path))
            }
            .buttonStyle(OMAIconButtonStyle(size: 30))
            .help("Open \(doc.path) in de standaardeditor")
            .accessibilityLabel("Open \(doc.title)")
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }
}
