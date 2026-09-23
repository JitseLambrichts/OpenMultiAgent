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
                    ProgressView("Loading projects…")
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
                    .accessibilityLabel("Projects")
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
                OMASearchField(prompt: "Search projects", text: $model.searchQuery, accessibilityLabel: "Search projects")
                    .frame(maxWidth: 520)

                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.load() }
                }
                .buttonStyle(.omaIcon)
                .help("Refresh projects")
                .accessibilityLabel("Refresh projects")

                Spacer(minLength: 0)

                Button("Add Project", systemImage: "folder.badge.plus") {
                    chooseProject()
                }
                .buttonStyle(.omaPrimary)
                .help("Add a Git repository (⌘O)")
            }

            HStack(alignment: .firstTextBaseline) {
                PageTitle(
                    title: "Welcome back 👋",
                    subtitle: "Your projects and active agent workspaces in one quiet place."
                )
                Spacer()
                Text("\(model.projects.count) projects")
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
            Label("No projects yet", systemImage: "shippingbox")
        } description: {
            Text("Add a Git repository to manage sessions, changes, and knowledge.")
        } actions: {
            Button("Add Project", systemImage: "folder.badge.plus") {
                chooseProject()
            }
            .buttonStyle(.omaPrimary)
        }
    }

    private var failureState: some View {
        ContentUnavailableView {
            Label("Service unavailable", systemImage: "bolt.horizontal.circle")
        } description: {
            Text(model.notice?.message ?? "OpenMultiAgent could not load projects.")
        } actions: {
            Button("Try Again") {
                Task { await model.load() }
            }
            .buttonStyle(.omaPrimary)
        }
    }

    private func noticeBanner(_ notice: ProjectsNotice) -> some View {
        InlineNotice(notice.message, actionTitle: notice.action == .retry ? "Retry" : "Choose Folder") {
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
