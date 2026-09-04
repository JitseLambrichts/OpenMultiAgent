import AppKit
import SwiftUI

struct ProjectsDashboard: View {
    @Bindable var model: ProjectsModel
    let onOpen: (ProjectDTO) -> Void
    let onNewSession: (ProjectDTO?) -> Void

    private let columns = [
        GridItem(.adaptive(minimum: 300, maximum: 420), spacing: 16)
    ]

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()

            Group {
                switch model.state {
                case .idle, .loading:
                    ProgressView("Projecten laden…")
                        .controlSize(.large)
                case .empty:
                    emptyState
                case .failed:
                    failureState
                case .content:
                    projectGrid
                }
            }
        }
        .navigationTitle("Projecten")
        .searchable(text: $model.searchQuery, prompt: "Zoek projecten")
        .toolbar {
            ToolbarItemGroup {
                Button("Vernieuw", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .help("Vernieuw projecten")
                .accessibilityLabel("Vernieuw projecten")

                Button("Voeg project toe", systemImage: "folder.badge.plus") {
                    chooseProject()
                }
                .help("Voeg een Git-repository toe (⌘O)")
                .buttonStyle(.borderedProminent)
                .tint(OMAColor.accent)
            }
        }
        .task {
            guard model.state == .idle else { return }
            await model.load()
        }
    }

    private var projectGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                dashboardHeader

                if let notice = model.notice {
                    noticeBanner(notice)
                }

                if model.filteredProjects.isEmpty {
                    ContentUnavailableView.search(text: model.searchQuery)
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
                        ForEach(model.filteredProjects) { project in
                            ProjectCard(
                                project: project,
                                onOpen: { onOpen(project) },
                                onNewSession: { onNewSession(project) },
                                onRemove: { Task { await model.removeProject(id: project.id) } }
                            )
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Projecten")
                }
            }
            .padding(28)
        }
    }

    private var dashboardHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Command Center")
                    .font(.largeTitle.weight(.semibold))
                Text("Je projecten en actieve agentwerkruimtes op één rustige plek.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(model.projects.count) projecten")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nog geen projecten", systemImage: "shippingbox")
        } description: {
            Text("Voeg een Git-repository toe om sessies, wijzigingen en kennis te beheren.")
        } actions: {
            Button("Voeg project toe", systemImage: "folder.badge.plus") {
                chooseProject()
            }
            .buttonStyle(.borderedProminent)
            .tint(OMAColor.accent)
        }
    }

    private var failureState: some View {
        ContentUnavailableView {
            Label("Service niet bereikbaar", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(model.notice?.message ?? "OpenMultiAgent kon de projecten niet laden.")
        } actions: {
            Button("Probeer opnieuw") {
                Task { await model.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(OMAColor.accent)
        }
    }

    private func noticeBanner(_ notice: ProjectsNotice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(OMAColor.attention)
            Text(notice.message)
                .font(.callout)
            Spacer()
            Button(notice.action == .retry ? "Opnieuw" : "Kies map") {
                if notice.action == .retry {
                    Task { await model.load() }
                } else {
                    chooseProject()
                }
            }
        }
        .padding(12)
        .background(OMAColor.attention.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(OMAColor.attention.opacity(0.22))
        }
    }

    private func chooseProject() {
        ProjectChooser.choose { url in
            Task { await model.addProject(url: url) }
        }
    }
}
