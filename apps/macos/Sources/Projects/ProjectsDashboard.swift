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
        .task {
            guard model.state == .idle else { return }
            await model.load()
        }
    }

    private var projectGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
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
            .padding(.horizontal, 28)
            .padding(.top, 36)
            .padding(.bottom, 28)
        }
    }

    private var dashboardHeader: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 12) {
                OMASearchField(prompt: "Zoek projecten", text: $model.searchQuery, accessibilityLabel: "Zoek projecten")
                    .frame(maxWidth: 520)

                Button("Vernieuw", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .buttonStyle(.omaIcon)
                .help("Vernieuw projecten")
                .accessibilityLabel("Vernieuw projecten")

                Spacer(minLength: 0)

                Button("Voeg project toe", systemImage: "folder.badge.plus") {
                    chooseProject()
                }
                .buttonStyle(.omaPrimary)
                .help("Voeg een Git-repository toe (⌘O)")
            }

            HStack(alignment: .firstTextBaseline) {
                PageTitle(
                    title: "Welkom terug 👋",
                    subtitle: "Je projecten en actieve agentwerkruimtes op één rustige plek."
                )
                Spacer()
                Text("\(model.projects.count) projecten")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(OMAColor.surface, in: Capsule())
            }
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
            .buttonStyle(.omaPrimary)
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
            .buttonStyle(.omaPrimary)
        }
    }

    private func noticeBanner(_ notice: ProjectsNotice) -> some View {
        InlineNotice(notice.message, actionTitle: notice.action == .retry ? "Opnieuw" : "Kies map") {
            if notice.action == .retry {
                Task { await model.load() }
            } else {
                chooseProject()
            }
        }
    }

    private func chooseProject() {
        ProjectChooser.choose { url in
            Task { await model.addProject(url: url) }
        }
    }
}
