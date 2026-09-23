import SwiftUI

/// Memory search plus project-scoped browsing. Used as the global Memory
/// destination and as the Memory tab inside a session workspace.
struct MemorySearchView: View {
    @State private var model: MemorySearchModel
    let projects: [ProjectDTO]
    let app: AppModel?
    let scopeRepoPath: String?
    @FocusState private var queryFocused: Bool
    @State private var query = ""

    init(client: any DesktopAPI, scopeRepoPath: String?, projects: [ProjectDTO], app: AppModel?) {
        _model = State(initialValue: MemorySearchModel(client: client, repoPath: scopeRepoPath))
        self.scopeRepoPath = scopeRepoPath
        self.projects = projects
        self.app = app
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            OMAColor.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if scopeRepoPath == nil {
                        header
                    }
                    searchBar
                    if let notice = model.notice {
                        InlineNotice(notice, actionTitle: "Retry") {
                            Task { await model.loadRecent() }
                        }
                    }
                    content
                }
                .padding(.horizontal, 28)
                .padding(.top, scopeRepoPath == nil ? 36 : 8)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .task { await model.loadRecent() }
        .onAppear { consumeSearchCommand() }
        .onChange(of: app?.pendingCommand) { _, _ in consumeSearchCommand() }
        .onChange(of: app?.reconciliationTick) { _, _ in Task { await model.loadRecent() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            PageTitle(title: "Memory", subtitle: "Decisions, invariants, and how-tos from all of your projects.")
            Spacer()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            OMASearchField(
                prompt: "Search decisions, invariants, how-tos…",
                text: $query,
                isBusy: model.isSearching,
                focus: $queryFocused,
                accessibilityLabel: "Search Memory"
            )
            .onChange(of: query) { _, value in model.updateQuery(value) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            if projects.count > 1 || model.repoPath == nil {
                Picker("Project", selection: Binding(
                    get: { model.repoPath ?? "" },
                    set: { model.repoPath = $0.isEmpty ? nil : $0 }
                )) {
                    Text("All projects").tag("")
                    ForEach(projects) { project in
                        Text(project.displayName).tag(project.repoPath)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                .help("Limit to one project")
                .accessibilityLabel("Project")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recentList
        } else if model.hits.isEmpty && !model.isSearching {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(model.hits) { hit in
                    SearchHitRow(hit: hit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if model.recent.isEmpty {
            ContentUnavailableView {
                Label("No knowledge yet", systemImage: "brain.head.profile")
            } description: {
                Text("Decisions, invariants, and how-tos appear here once you promote knowledge from a session.")
            }
            .frame(maxWidth: .infinity, minHeight: 320)
        } else {
            LazyVStack(spacing: 10) {
                ForEach(model.recent) { memory in
                    MemoryRow(memory: memory)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func consumeSearchCommand() {
        guard let app, app.consume(.search) else { return }
        queryFocused = true
    }
}

struct MemoryRow: View {
    let memory: MemoryDTO

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(memory.kind.title, systemImage: memory.kind.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OMAColor.accent)
                Spacer()
                Text(memory.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(memory.title)
                .font(.headline)
            Text(memory.body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
            if let repoPath = memory.repoPath {
                Text(repoPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .omaCard()
        .accessibilityElement(children: .combine)
    }
}

struct SearchHitRow: View {
    let hit: SearchHitDTO

    var body: some View {
        switch hit {
        case .memory(let memory):
            VStack(alignment: .leading, spacing: 6) {
                Label(memory.kind.title, systemImage: memory.kind.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(OMAColor.accent)
                Text(memory.title).font(.headline)
                Text(memory.body).font(.callout).foregroundStyle(.secondary).lineLimit(4)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .omaCard()
            .accessibilityElement(children: .combine)
        case .event(let event):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Label("Transcript · \(event.agent.capitalized)", systemImage: "text.bubble")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(event.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(event.text)
                    .font(.callout)
                    .lineLimit(6)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .omaCard()
            .accessibilityElement(children: .combine)
        }
    }
}
