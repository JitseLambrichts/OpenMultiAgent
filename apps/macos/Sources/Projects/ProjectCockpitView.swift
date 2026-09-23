import SwiftUI

/// Project-level view: overview of sessions/knowledge, or the equivalent
/// terminal grid without a primary session. Ending happens per session (row,
/// detail, or cell menu), never via a global button that would end an
/// implicit primary session.
enum CockpitTab: String, CaseIterable, Identifiable {
    case overzicht
    case terminals
    case code

    var id: Self { self }

    var title: String {
        switch self {
        case .overzicht: "Overview"
        case .terminals: "Terminals"
        case .code: "Code"
        }
    }

    var symbol: String {
        switch self {
        case .overzicht: "square.grid.2x2"
        case .terminals: "terminal"
        case .code: "chevron.left.forwardslash.chevron.right"
        }
    }
}

struct ProjectCockpitView: View {
    @State private var model: ProjectCockpitModel
    @State private var terminals: TerminalWorkspaceModel
    @State private var editor: CodeWorkspaceModel
    @State private var cockpitTab: CockpitTab = .overzicht
    @State private var pickerCellID: UUID?
    @State private var knownTitles: [String: String] = [:]
    @State private var diffTarget: FileDiffTarget?
    @SceneStorage("terminal-layout") private var storedLayout: TerminalLayout = .single
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let panelColumns = [GridItem(.adaptive(minimum: 320, maximum: 640), spacing: 16, alignment: .top)]

    init(project: ProjectDTO, app: AppModel) {
        _model = State(initialValue: ProjectCockpitModel(project: project, client: app.client))
        _terminals = State(initialValue: TerminalWorkspaceModel(factory: SidecarTerminalFactory(client: app.client)))
        _editor = State(initialValue: CodeWorkspaceModel(project: project, client: app.client))
        self.app = app
    }

    var body: some View {
        ZStack {
            OMAColor.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 28)
                    .padding(.top, 36)
                    .padding(.bottom, 16)
                tabBar
                    .padding(.horizontal, 28)
                    .padding(.bottom, 16)
                if let endNotice = model.endNotice {
                    InlineNotice(endNotice, actionTitle: "Dismiss") { model.clearEndNotice() }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                }
                if let notice = model.notice {
                    InlineNotice(notice.message, actionTitle: "Retry") { Task { await model.load() } }
                        .padding(.horizontal, 28)
                        .padding(.bottom, 12)
                }
                content
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
        .sheet(item: $pickerCellID) { cellID in
            SessionPickerSheet(
                client: app.client,
                repoPath: model.project.repoPath,
                excluded: Set(terminals.occupiedSessionIDs),
                symbolForAgent: { app.symbol(for: $0) }
            ) { session in
                knownTitles[session.id] = session.session.displayTitle
                Task { try? await terminals.open(sessionID: session.id, into: cellID) }
            }
        }
        .sheet(item: $diffTarget) { target in
            FileDiffSheet(target: target, client: app.client) { opened in
                cockpitTab = .code
                Task { await editor.reveal(path: opened.file.path, sessionID: opened.sessionID) }
            }
        }
        .confirmationDialog(
            "This layout has fewer cells than open terminals",
            isPresented: Binding(get: { terminals.pendingLayoutConfirmation != nil }, set: { if !$0 { terminals.cancelPendingLayout() } }),
            titleVisibility: .visible
        ) {
            if let requested = terminals.pendingLayoutConfirmation {
                let surplus = Array(terminals.occupiedSessionIDs.dropFirst(requested.capacity))
                Button("Close \(surplus.count) terminal attachment(s)", role: .destructive) {
                    terminals.confirmPendingLayout(closing: surplus)
                }
            }
            Button("Cancel", role: .cancel) { terminals.cancelPendingLayout() }
        } message: {
            Text("The sessions keep running; only the local terminal attachments are closed.")
        }
        .alert(item: Binding(get: { model.alert }, set: { if $0 == nil { model.dismissAlert() } })) { alert in
            cockpitAlert(alert)
        }
        .task {
            await model.load()
            terminals.requestLayout(storedLayout)
            // Pick up shortcuts (⌃1–⌃4) that arrived while the cockpit was
            // not visible (for example from session detail).
            if let layout = app.consumeTerminalLayout() {
                cockpitTab = .terminals
                terminals.requestLayout(layout)
            }
            await openPendingEditor()
        }
        .onChange(of: terminals.layout) { _, layout in storedLayout = layout }
        .onChange(of: app.pendingCommand) { _, _ in
            if app.consume(.saveEditor) {
                Task { await editor.saveSelected() }
            }
            if let layout = app.consumeTerminalLayout() {
                cockpitTab = .terminals
                terminals.requestLayout(layout)
            }
        }
        .onChange(of: app.pendingEditorOpen) { _, _ in
            Task { await openPendingEditor() }
        }
        .onChange(of: app.reconciliationTick) { _, _ in
            Task {
                await model.load()
                await editor.reloadCleanBuffers()
            }
        }
        .overlay {
            if model.isLoading && model.sessions.isEmpty {
                ProgressView("Loading project…")
                    .padding(20)
                    .omaCard()
            }
        }
        .omaPanelAnimation(model.sessions.count, reduceMotion: reduceMotion)
    }

    private var tabBar: some View {
        HStack(spacing: 10) {
            OMAPillPicker(
                options: CockpitTab.allCases,
                selection: $cockpitTab,
                accessibilityLabel: "Project view",
                title: { $0.title },
                symbol: { $0.symbol }
            )
            .help("Switch between overview, terminals, and code")
            Spacer()
            if cockpitTab == .terminals {
                OMAPillPicker(
                    options: TerminalLayout.allCases,
                    selection: Binding(get: { terminals.layout }, set: { terminals.requestLayout($0) }),
                    iconOnly: true,
                    accessibilityLabel: "Terminal layout",
                    title: { $0.title },
                    symbol: { $0.symbol }
                )
                .help("Terminal layout (⌃1 – ⌃4)")
                Button("Open in Grid", systemImage: "plus.rectangle.on.rectangle") {
                    pickerCellID = terminals.cells.first(where: { !$0.isOccupied })?.id ?? UUID()
                }
                .buttonStyle(.omaIcon)
                .help("Open a session from this project in the grid")
                .disabled(!terminals.canOpenMore)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch cockpitTab {
        case .overzicht:
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sessionSection("Active work", symbol: "bolt.fill", sessions: model.activeSessions,
                                   empty: "No active sessions. Start one with New Session (⌘N).")
                    LazyVGrid(columns: panelColumns, alignment: .leading, spacing: 16) {
                        decisionsPanel
                        changesPanel
                        docsPanel
                    }
                    sessionSection("Recent sessions", symbol: "clock", sessions: model.recentSessions,
                                   empty: "Completed sessions appear here with their extracted knowledge.")
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        case .terminals:
            terminalsSection
        case .code:
            CodeWorkspaceView(
                model: editor,
                sessions: model.sessions,
                terminals: terminals,
                onOpenTerminals: { cockpitTab = .terminals },
                onStartShell: { app.request(.newSession) }
            )
        }
    }

    private var terminalsSection: some View {
        Group {
            if let error = terminals.errorMessage {
                ContentUnavailableView {
                    Label("Terminal unavailable", systemImage: "terminal")
                } description: {
                    Text(error)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                TerminalGridView(
                    model: terminals,
                    sessionActiveFor: { id in model.session(withID: id)?.session.isActive ?? true },
                    titleFor: { id in
                        knownTitles[id]
                            ?? model.session(withID: id)?.session.displayTitle
                            ?? String(id.prefix(8))
                    },
                    onOpenDetail: { id in
                        if let view = model.session(withID: id) {
                            model.selectedSessionID = view.id
                            app.openSession(view)
                        }
                    }
                ) { cellID in pickerCellID = cellID }
            }
        }
    }

    private func openPendingEditor() async {
        guard let request = app.consumeEditorOpen() else { return }
        cockpitTab = .code
        await editor.reveal(path: request.path, sessionID: request.sessionID)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.load() } }
                .buttonStyle(.omaIcon)
                .help("Refresh sessions, changes, and knowledge")
                .symbolEffect(.rotate, isActive: model.isLoading)
            Button("Inspector", systemImage: "sidebar.trailing") { app.isInspectorVisible.toggle() }
                .buttonStyle(.omaIcon)
                .help("Show or hide the inspector (⌥⌘I)")
            Button("New Session", systemImage: "plus") { app.request(.newSession) }
                .buttonStyle(.omaPrimary)
                .help("Start a new agent session (⌘N)")
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            Button("Back to Projects", systemImage: "chevron.left") { app.closeProject() }
                .buttonStyle(.omaIcon)
                .help("Back to Projects")
            AccentDisc(symbol: "shippingbox.fill", size: 40)
            VStack(alignment: .leading, spacing: 6) {
                Text(model.project.displayName)
                    .font(.system(size: 26, weight: .bold))
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 12) {
                    Label("\(model.activeSessions.count) active", systemImage: "bolt")
                    Label("\(model.changedFileCount) changed", systemImage: "doc.badge.ellipsis")
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
            PanelHeader("Recent decisions", symbol: "checkmark.seal") {
                Button("All", systemImage: "arrow.up.forward") { app.selection = .memory }
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(OMAColor.accent)
                    .help("Open all memory")
            }
            if model.recentDecisions.isEmpty {
                Text("No promoted knowledge for this project yet.")
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
            PanelHeader("Changed files", symbol: "doc.badge.ellipsis") {
                Text("\(model.changedFileCount)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if model.changes.isEmpty {
                Text("No outstanding changes in active sessions.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.changes) { change in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(change.session.session.displayTitle)
                            .font(.subheadline.weight(.medium))
                        ForEach(change.files.prefix(6)) { file in
                            ChangedFileRow(file: file) {
                                diffTarget = FileDiffTarget(
                                    projectID: model.project.id,
                                    sessionID: change.session.id,
                                    sessionTitle: change.session.session.displayTitle,
                                    file: file
                                )
                            }
                        }
                        if change.files.count > 6 {
                            Text("+ \(change.files.count - 6) more")
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
                Button("All", systemImage: "arrow.up.forward") { app.selection = .docs }
                    .labelStyle(.titleOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(OMAColor.accent)
                    .help("Open all Living Docs")
            }
            if model.docs.isEmpty {
                Text("No documentation yet. Promote knowledge from a completed session.")
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
        secondaryButton: .cancel(Text("Cancel"))
    )
}

struct ChangedFileRow: View {
    let file: ChangedFileDTO
    var action: (() -> Void)? = nil

    private var status: (text: String, symbol: String, color: Color) {
        switch file.status.trimmingCharacters(in: .whitespaces) {
        case "M", "MM": ("Modified", "pencil", OMAColor.attention)
        case "A", "AM": ("Added", "plus", OMAColor.positive)
        case "D": ("Deleted", "minus", OMAColor.negative)
        case "R": ("Renamed", "arrow.right", OMAColor.accent)
        case "??": ("New", "sparkle", OMAColor.positive)
        default: (file.status, "questionmark", Color.secondary)
        }
    }

    var body: some View {
        let row = HStack(spacing: 8) {
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
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(file.path), \(status.text)")

        if let action {
            Button(action: action) { row }
                .buttonStyle(.plain)
                .accessibilityHint("Show the diff and open in the editor")
        } else {
            row
        }
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
                LabeledContent("Name", value: project.displayName)
                LabeledContent("Path") {
                    Text(project.repoPath).font(.caption.monospaced()).textSelection(.enabled)
                }
                LabeledContent("Opened", value: project.lastOpenedAt.formatted(date: .abbreviated, time: .shortened))
            }
            if let session {
                SessionInspectorSections(session: session, status: status, symbolForAgent: symbolForAgent)
            } else {
                Section("Session") {
                    Text("Select a session for worktree and run details.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(OMAColor.surface)
    }
}
