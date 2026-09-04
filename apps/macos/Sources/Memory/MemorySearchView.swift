import SwiftUI

/// Memory search plus project-scoped browsing. Used as the global Memory
/// destination and as the Memory tab inside a session workspace.
struct MemorySearchView: View {
    @State private var model: MemorySearchModel
    let projects: [ProjectDTO]
    let app: AppModel?
    @FocusState private var queryFocused: Bool
    @State private var query = ""

    init(client: any DesktopAPI, scopeRepoPath: String?, projects: [ProjectDTO], app: AppModel?) {
        _model = State(initialValue: MemorySearchModel(client: client, repoPath: scopeRepoPath))
        self.projects = projects
        self.app = app
    }

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 16) {
                searchBar
                if let notice = model.notice {
                    InlineNotice(notice, actionTitle: "Opnieuw") {
                        Task { await model.loadRecent() }
                    }
                }
                content
            }
            .padding(24)
        }
        .navigationTitle("Geheugen")
        .task { await model.loadRecent() }
        .onAppear { consumeSearchCommand() }
        .onChange(of: app?.pendingCommand) { _, _ in consumeSearchCommand() }
        .onChange(of: app?.reconciliationTick) { _, _ in Task { await model.loadRecent() } }
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Zoek beslissingen, invarianten, how-tos…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onChange(of: query) { _, value in model.updateQuery(value) }
                    .accessibilityLabel("Zoek in geheugen")
                if model.isSearching {
                    Image(systemName: "progress.indicator")
                        .symbolEffect(.variableColor.iterative, isActive: true)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Zoeken")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(OMAColor.separator) }

            if projects.count > 1 || model.repoPath == nil {
                Picker("Project", selection: Binding(
                    get: { model.repoPath ?? "" },
                    set: { model.repoPath = $0.isEmpty ? nil : $0 }
                )) {
                    Text("Alle projecten").tag("")
                    ForEach(projects) { project in
                        Text(project.displayName).tag(project.repoPath)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
                .help("Beperk tot één project")
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recentList
        } else if model.hits.isEmpty && !model.isSearching {
            ContentUnavailableView.search(text: query)
        } else {
            List(model.hits) { hit in
                SearchHitRow(hit: hit)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var recentList: some View {
        if model.recent.isEmpty {
            ContentUnavailableView {
                Label("Nog geen kennis", systemImage: "brain.head.profile")
            } description: {
                Text("Beslissingen, invarianten en how-tos verschijnen hier zodra je kennis uit een sessie promoveert.")
            }
        } else {
            List(model.recent) { memory in
                MemoryRow(memory: memory)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
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
        .padding(14)
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
            .padding(14)
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
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .omaCard()
            .accessibilityElement(children: .combine)
        }
    }
}
