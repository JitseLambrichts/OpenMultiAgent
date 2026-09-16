import SwiftUI

struct ProjectCockpitView: View {
    @State private var model: ProjectCockpitModel
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelColumns = [GridItem(.adaptive(minimum: 320, maximum: 640), spacing: 16, alignment: .top)]

    init(project: ProjectDTO, app: AppModel) {
        _model = State(initialValue: ProjectCockpitModel(project: project, client: app.client))
        self.app = app
    }

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let endNotice = model.endNotice {
                        InlineNotice(endNotice, actionTitle: "Sluiten") { model.clearEndNotice() }
                    }
                    if let notice = model.notice {
                        InlineNotice(notice.message, actionTitle: "Opnieuw") { Task { await model.load() } }
                    }
                    sessionSection("Actief werk", symbol: "bolt.fill", sessions: model.activeSessions,
                                   empty: "Geen actieve sessies. Start er een met Nieuwe sessie (⌘N).")
                    LazyVGrid(columns: panelColumns, alignment: .leading, spacing: 16) {
                        decisionsPanel
                        changesPanel
                        docsPanel
                    }
                    sessionSection("Recente sessies", symbol: "clock", sessions: model.recentSessions,
                                   empty: "Afgeronde sessies verschijnen hier met hun geëxtraheerde kennis.")
                }
                .padding(.horizontal, 28)
                .padding(.top, 36)
                .padding(.bottom, 28)
            }
        }
        .inspector(isPresented: Binding(get: { app.isInspectorVisible }, set: { app.isInspectorVisible = $0 })) {
            ProjectInspector(project: model.project, session: model.selectedSession,
                             status: model.selectedSessionID.flatMap { model.statuses[$0] },
                             symbolForAgent: { app.symbol(forAgentID: $0) })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .sheet(item: $model.switchTarget) { target in
            SwitchAgentSheet(session: target, agents: app.availableAgents, displayName: { app.displayName(for: $0) }, symbol: { app.symbol(for: $0) }) { agent, prompt in
                await model.switchAgent(sessionID: target.id, agent: agent, prompt: prompt)
            }
        }
        .alert(item: Binding(get: { model.alert }, set: { if $0 == nil { model.dismissAlert() } })) { alert in
            cockpitAlert(alert)
        }
        .task { await model.load() }
        .onChange(of: app.reconciliationTick) { _, _ in Task { await model.load() } }
        .overlay {
            if model.isLoading && model.sessions.isEmpty {
                ProgressView("Project laden…")
                    .padding(20)
                    .omaCard()
            }
        }
        .omaPanelAnimation(model.sessions.count, reduceMotion: reduceMotion)
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Vernieuw", systemImage: "arrow.clockwise") { Task { await model.load() } }
                .buttonStyle(.omaIcon)
                .help("Vernieuw sessies, wijzigingen en kennis")
                .symbolEffect(.rotate, isActive: model.isLoading)
            Button("Inspector", systemImage: "sidebar.trailing") { app.isInspectorVisible.toggle() }
                .buttonStyle(.omaIcon)
                .help("Toon of verberg de inspector (⌥⌘I)")
            Button("Nieuwe sessie", systemImage: "plus") { app.request(.newSession) }
                .buttonStyle(.omaPrimary)
                .help("Start een nieuwe agentsessie (⌘N)")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Button("Terug naar projecten", systemImage: "chevron.left") { app.closeProject() }
                .buttonStyle(.omaIcon)
                .help("Terug naar projecten")
            AccentDisc(symbol: "shippingbox.fill", size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.project.displayName)
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    Label("\(model.activeSessions.count) actief", systemImage: "bolt")
                    Label("\(model.changedFileCount) gewijzigd", systemImage: "doc.badge.ellipsis")
                    if !model.branches.isEmpty {
                        Label(model.branches.joined(separator: ", "), systemImage: "arrow.triangle.branch")
                            .font(.subheadline.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                Text(model.project.repoPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            actions
        }
    }

    private func sessionSection(_ title: String, symbol: String, sessions: [SessionViewDTO], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(title, symbol: symbol) {
                Text("\(sessions.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if sessions.isEmpty {
                Text(empty)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                    .padding(.horizontal, 20)
                    .omaCard()
            } else {
                ForEach(sessions) { view in
                    SessionRow(view: view, actions: actions(for: view), agentSymbol: view.currentAgent.map { app.symbol(for: $0) })
                        .opacity(model.busySessionIDs.contains(view.id) ? 0.55 : 1)
                        .disabled(model.busySessionIDs.contains(view.id))
                }
            }
        }
    }

    private func actions(for view: SessionViewDTO) -> SessionRowActions {
        SessionRowActions(
            open: {
                model.selectedSessionID = view.id
                app.openSession(view)
            },
            resume: { Task { await model.resume(sessionID: view.id) } },
            switchAgent: { model.switchTarget = view },
            end: { model.requestEnd(sessionID: view.id) },
            remove: { model.requestRemove(sessionID: view.id) }
        )
    }

    private var decisionsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Recente beslissingen", symbol: "checkmark.seal") {
                Button("Alles", systemImage: "arrow.up.forward") { app.selection = .memory }
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(OMAColor.accent)
                    .help("Open het volledige geheugen")
            }
            if model.recentDecisions.isEmpty {
                Text("Nog geen gepromoveerde kennis voor dit project.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recentDecisions.prefix(5)) { memory in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(memory.title, systemImage: memory.kind.symbol)
                            .font(.body.weight(.medium))
                            .lineLimit(2)
                        Text(memory.body)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .omaCard()
    }

    private var changesPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Gewijzigde bestanden", symbol: "doc.badge.ellipsis") {
                Text("\(model.changedFileCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.changes.isEmpty {
                Text("Geen openstaande wijzigingen in actieve sessies.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.changes) { change in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(change.session.session.displayTitle)
                            .font(.subheadline.weight(.medium))
                        ForEach(change.files.prefix(6)) { file in
                            ChangedFileRow(file: file)
                        }
                        if change.files.count > 6 {
                            Text("+ \(change.files.count - 6) meer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .omaCard()
    }

    private var docsPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader("Living Docs", symbol: "doc.text") {
                Button("Alles", systemImage: "arrow.up.forward") { app.selection = .docs }
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(OMAColor.accent)
                    .help("Open alle Living Docs")
            }
            if model.docs.isEmpty {
                Text("Nog geen documentatie. Promoveer kennis vanuit een afgeronde sessie.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.docs) { doc in
                    LivingDocRow(doc: doc, repoPath: model.project.repoPath)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .omaCard()
    }

    // MARK: Alerts

    private func cockpitAlert(_ alert: CockpitAlert) -> Alert {
        sessionLifecycleAlert(alert) { action in
            Task { await model.perform(action, for: alert.sessionID) }
        }
    }
}

func sessionLifecycleAlert(_ alert: CockpitAlert, perform: @escaping (CockpitAlertAction) -> Void) -> Alert {
    let primary = Alert.Button.destructive(Text(alert.primaryAction.title)) {
        perform(alert.primaryAction)
    }
    if let secondary = alert.secondaryAction {
        return Alert(
            title: Text(alert.title),
            message: Text(alert.message),
            primaryButton: primary,
            secondaryButton: .destructive(Text(secondary.title)) {
                perform(secondary)
            }
        )
    }
    return Alert(
        title: Text(alert.title),
        message: Text(alert.message),
        primaryButton: primary,
        secondaryButton: .cancel(Text("Annuleer"))
    )
}

struct ChangedFileRow: View {
    let file: ChangedFileDTO

    private var status: (text: String, symbol: String, color: Color) {
        switch file.status.trimmingCharacters(in: .whitespaces) {
        case "M", "MM": ("Gewijzigd", "pencil", OMAColor.attention)
        case "A", "AM": ("Toegevoegd", "plus", OMAColor.positive)
        case "D": ("Verwijderd", "minus", OMAColor.negative)
        case "R": ("Hernoemd", "arrow.right", OMAColor.accent)
        case "??": ("Nieuw", "sparkle", OMAColor.positive)
        default: (file.status, "questionmark", Color.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(file.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(status.text)
                .font(.caption)
                .foregroundStyle(status.color)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.path), \(status.text)")
    }
}

/// Repository, worktree, and session metadata. Read-only.
struct ProjectInspector: View {
    let project: ProjectDTO
    let session: SessionViewDTO?
    let status: SessionStatusDTO?
    var symbolForAgent: (String) -> String = { AgentKind(rawValue: $0).symbol }

    var body: some View {
        List {
            Section("Repository") {
                LabeledContent("Naam", value: project.displayName)
                LabeledContent("Pad") {
                    Text(project.repoPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Geopend", value: project.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let session {
                SessionInspectorSections(session: session, status: status, symbolForAgent: symbolForAgent)
            } else {
                Section("Sessie") {
                    Text("Selecteer een sessie voor worktree- en rundetails.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OMAColor.surface)
    }
}
