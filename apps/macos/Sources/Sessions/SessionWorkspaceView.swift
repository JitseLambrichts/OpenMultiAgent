import SwiftUI

struct SessionWorkspaceView: View {
    @State private var model: SessionWorkspaceModel
    @State private var terminals: TerminalWorkspaceModel
    @State private var pickerCellID: UUID?
    @State private var knownTitles: [String: String] = [:]
    @State private var showsEndConfirmation = false
    @SceneStorage("terminal-layout") private var storedLayout: TerminalLayout = .single
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: SessionViewDTO, app: AppModel) {
        _model = State(initialValue: SessionWorkspaceModel(session: session, client: app.client))
        _terminals = State(initialValue: TerminalWorkspaceModel(factory: SidecarTerminalFactory(client: app.client)))
        self.app = app
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let notice = model.notice {
                InlineNotice(notice)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
            Divider()
            content
        }
        .background(OMAColor.canvas)
        .navigationTitle(model.session.session.displayTitle)
        .toolbar { toolbarContent }
        .inspector(isPresented: Binding(get: { app.isInspectorVisible }, set: { app.isInspectorVisible = $0 })) {
            SessionInspector(session: model.session, status: model.status, symbolForAgent: { app.symbol(forAgentID: $0) })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .sheet(isPresented: Binding(get: { model.route == .promotionPreview }, set: { if !$0 { model.dismissRoute() } })) {
            PromotionReviewView(
                state: model.promotion,
                sessionTitle: model.session.session.displayTitle,
                onApply: { Task { await model.applyPromotion() } },
                onRetry: { Task { await model.retryPromotion() } },
                onClose: { model.dismissRoute(); app.reconcile() }
            )
        }
        .sheet(item: $pickerCellID) { cellID in
            SessionPickerSheet(
                client: app.client,
                repoPath: model.session.session.repoPath,
                excluded: Set(terminals.occupiedSessionIDs),
                symbolForAgent: { app.symbol(for: $0) }
            ) { session in
                knownTitles[session.id] = session.session.displayTitle
                Task { try? await terminals.open(sessionID: session.id, into: cellID) }
            }
        }
        .confirmationDialog(
            "Deze indeling heeft minder cellen dan er terminals open zijn",
            isPresented: Binding(get: { terminals.pendingLayoutConfirmation != nil }, set: { if !$0 { terminals.cancelPendingLayout() } }),
            titleVisibility: .visible
        ) {
            if let requested = terminals.pendingLayoutConfirmation {
                let surplus = Array(terminals.occupiedSessionIDs.dropFirst(requested.capacity))
                Button("Sluit \(surplus.count) terminalkoppeling(en)", role: .destructive) {
                    terminals.confirmPendingLayout(closing: surplus)
                }
            }
            Button("Annuleer", role: .cancel) { terminals.cancelPendingLayout() }
        } message: {
            Text("De sessies blijven draaien; alleen de lokale terminalkoppelingen worden gesloten.")
        }
        .alert("Sessie beëindigen?", isPresented: $showsEndConfirmation) {
            Button("Beëindig", role: .destructive) {
                Task {
                    if await model.endSession() { app.reconcile() }
                }
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            Text("De tmux-sessie stopt en de agent wordt afgesloten. Transcript, worktree en geheugen blijven bewaard.")
        }
        .task {
            await model.loadStatus()
            model.startAutoCheckLoop()
            terminals.requestLayout(storedLayout)
            await terminals.openReportingError(sessionID: model.session.id)
        }
        .onDisappear {
            Task { await model.stopAutoCheckLoop() }
        }
        .onChange(of: terminals.layout) { _, layout in storedLayout = layout }
        .onChange(of: app.pendingCommand) { _, _ in
            if let layout = app.consumeTerminalLayout() {
                model.tab = .terminal
                terminals.requestLayout(layout)
            }
        }
        .onChange(of: app.reconciliationTick) { _, _ in Task { await model.loadStatus() } }
        .onChange(of: model.tab) { _, tab in
            if tab == .transcript && !model.hasLoadedTranscript {
                Task { await model.loadNewestTranscript() }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            let agent = model.session.currentAgent
            Image(systemName: agent.map { app.symbol(for: $0) } ?? "terminal")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(agent?.tint ?? .secondary)
                .font(.title3)
                .frame(width: 34, height: 34)
                .background(OMAColor.elevated, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text(agent?.title ?? "Geen agent").font(.headline)
                    if let branch = model.session.session.branch {
                        Text(branch).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 10) {
                    Label(model.runtime, systemImage: "timer")
                    if let status = model.status {
                        Label("\(status.changedFiles.count) bestanden", systemImage: "doc.badge.ellipsis")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            liveStatus
            Picker("Tabblad", selection: $model.tab) {
                ForEach(WorkspaceTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 380)
            .help("Wissel tussen terminal, wijzigingen, geheugen en transcript")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(OMAColor.surface)
        .accessibilityElement(children: .contain)
    }

    private var liveStatus: some View {
        let session = model.session
        return Group {
            if session.session.isActive && session.tmuxAlive {
                StatusBadge(text: "Live", symbol: "circle.fill", color: OMAColor.positive)
            } else if session.session.isActive {
                StatusBadge(text: "tmux niet gevonden", symbol: "exclamationmark.circle", color: OMAColor.attention)
            } else {
                StatusBadge(text: "Afgerond", symbol: "checkmark.circle", color: OMAColor.quiet)
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch model.tab {
        case .terminal:
            if let error = terminals.errorMessage {
                ContentUnavailableView {
                    Label("Terminal niet beschikbaar", systemImage: "terminal")
                } description: {
                    Text(error)
                } actions: {
                    Button("Probeer opnieuw") { Task { await terminals.openReportingError(sessionID: model.session.id) } }
                        .buttonStyle(.borderedProminent)
                        .tint(OMAColor.accent)
                }
            } else {
                TerminalGridView(
                    model: terminals,
                    titleFor: { id in knownTitles[id] ?? (id == model.session.id ? model.session.session.displayTitle : String(id.prefix(8))) }
                ) { cellID in pickerCellID = cellID }
            }
        case .changes:
            ChangesView(status: model.status, isLoading: model.isLoadingStatus, notice: model.notice) {
                Task { await model.loadStatus() }
            }
        case .memory:
            MemorySearchView(client: app.client, scopeRepoPath: model.session.session.repoPath,
                             projects: app.projects.projects, app: app)
        case .transcript:
            TranscriptView(model: model)
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Terug naar project", systemImage: "chevron.left") { app.closeSession() }
                .help("Terug naar de projectcockpit")
        }
        ToolbarItemGroup {
            if model.tab == .terminal {
                Picker("Indeling", selection: Binding(get: { terminals.layout }, set: { terminals.requestLayout($0) })) {
                    ForEach(TerminalLayout.allCases) { layout in
                        Label(layout.title, systemImage: layout.symbol).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .help("Terminalindeling (⌃1 – ⌃4)")
                .accessibilityLabel("Terminalindeling")
                Button("Open in raster", systemImage: "plus.rectangle.on.rectangle") {
                    pickerCellID = terminals.cells.first(where: { !$0.isOccupied })?.id ?? UUID()
                }
                .help("Open een andere sessie van dit project in het raster")
                .disabled(!terminals.canOpenMore)
            }
            Button("Inspector", systemImage: "sidebar.trailing") { app.isInspectorVisible.toggle() }
                .help("Toon of verberg de inspector (⌥⌘I)")
            Menu("Meer", systemImage: "ellipsis.circle") {
                Button("Vernieuw status", systemImage: "arrow.clockwise") { Task { await model.loadStatus() } }
                if model.session.session.isActive {
                    Button("Beëindig sessie…", systemImage: "stop.circle") { showsEndConfirmation = true }
                }
            }
            .help("Meer acties")
        }
        ToolbarItem(placement: .primaryAction) {
            if model.hasReviewableCandidates {
                Button("Promote Knowledge", systemImage: "checkmark.seal") { Task { await model.openPreview() } }
                    .help("Bekijk en pas de geëxtraheerde kennis toe")
                    .buttonStyle(.borderedProminent)
                    .tint(OMAColor.accent)
            } else if !model.session.session.isActive {
                Button("Extract Knowledge", systemImage: "sparkles") { Task { await model.extractKnowledge() } }
                    .help("Extraheer beslissingen en invarianten uit het transcript")
                    .disabled(!model.canExtract)
                    .symbolEffect(.pulse, isActive: model.promotion == .extracting)
            }
        }
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// Project-scoped session picker for empty grid cells and Open in Grid.
struct SessionPickerSheet: View {
    let client: any DesktopAPI
    let repoPath: String
    let excluded: Set<String>
    var symbolForAgent: (AgentKind) -> String = { $0.symbol }
    let onPick: (SessionViewDTO) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [SessionViewDTO] = []
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Kies een sessie")
                .font(.title2.weight(.semibold))
            Text("Alleen sessies van dit project. Een sessie kan maar in één cel staan.")
                .foregroundStyle(.secondary)
            if let notice {
                InlineNotice(notice)
            }
            let available = sessions.filter { !excluded.contains($0.id) }
            if available.isEmpty {
                ContentUnavailableView("Geen andere sessies", systemImage: "terminal",
                                       description: Text("Start een nieuwe sessie vanuit de projectcockpit."))
                    .frame(minHeight: 200)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(available) { session in
                            SessionRow(view: session, agentSymbol: session.currentAgent.map { symbolForAgent($0) }) {
                                onPick(session)
                                dismiss()
                            }
                        }
                    }
                }
                .frame(minHeight: 200, maxHeight: 420)
            }
            HStack {
                Spacer()
                Button("Annuleer") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(OMAColor.canvas)
        .task {
            do {
                sessions = try await client.listSessions(repoPath: repoPath, status: nil)
            } catch {
                notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}
