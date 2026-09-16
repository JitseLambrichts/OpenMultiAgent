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
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            content
        }
        .background(OMAColor.canvas)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                let agent = model.session.currentAgent
                Button("Terug naar project", systemImage: "chevron.left") { app.closeSession() }
                    .buttonStyle(.omaIcon)
                    .help("Terug naar de projectcockpit")
                Image(systemName: agent.map { app.symbol(for: $0) } ?? "terminal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(agent?.tint ?? .secondary)
                    .frame(width: 40, height: 40)
                    .background(OMAColor.elevated, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Text(model.session.session.displayTitle)
                            .font(.system(size: 20, weight: .bold))
                            .lineLimit(1)
                            .accessibilityAddTraits(.isHeader)
                        liveStatus
                    }
                    HStack(spacing: 10) {
                        Text(agent?.title ?? "Geen agent")
                        if let branch = model.session.session.branch {
                            Text(branch).font(.caption.monospaced())
                        }
                        Label(model.runtime, systemImage: "timer")
                        if let status = model.status {
                            Label("\(status.changedFiles.count) bestanden", systemImage: "doc.badge.ellipsis")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }

            HStack(spacing: 10) {
                OMAPillPicker(
                    options: WorkspaceTab.allCases,
                    selection: $model.tab,
                    accessibilityLabel: "Tabblad",
                    title: { $0.title },
                    symbol: { $0.symbol }
                )
                .help("Wissel tussen terminal, wijzigingen, geheugen en transcript")
                Spacer()
                if model.tab == .terminal {
                    OMAPillPicker(
                        options: TerminalLayout.allCases,
                        selection: Binding(get: { terminals.layout }, set: { terminals.requestLayout($0) }),
                        iconOnly: true,
                        accessibilityLabel: "Terminalindeling",
                        title: { $0.title },
                        symbol: { $0.symbol }
                    )
                    .help("Terminalindeling (⌃1 – ⌃4)")
                    Button("Open in raster", systemImage: "plus.rectangle.on.rectangle") {
                        pickerCellID = terminals.cells.first(where: { !$0.isOccupied })?.id ?? UUID()
                    }
                    .buttonStyle(.omaIcon)
                    .help("Open een andere sessie van dit project in het raster")
                    .disabled(!terminals.canOpenMore)
                }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 16)
        .accessibilityElement(children: .contain)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Inspector", systemImage: "sidebar.trailing") { app.isInspectorVisible.toggle() }
                .buttonStyle(.omaIcon)
                .help("Toon of verberg de inspector (⌥⌘I)")
            OMAIconMenu(symbol: "ellipsis", title: "Meer acties") {
                Button("Vernieuw status", systemImage: "arrow.clockwise") { Task { await model.loadStatus() } }
                if model.session.session.isActive {
                    Button("Beëindig sessie…", systemImage: "stop.circle") { showsEndConfirmation = true }
                }
            }
            if model.hasReviewableCandidates {
                Button("Promote Knowledge", systemImage: "checkmark.seal") { Task { await model.openPreview() } }
                    .buttonStyle(.omaPrimary)
                    .help("Bekijk en pas de geëxtraheerde kennis toe")
            } else if !model.session.session.isActive {
                Button("Extract Knowledge", systemImage: "sparkles") { Task { await model.extractKnowledge() } }
                    .buttonStyle(.omaSecondary)
                    .help("Extraheer beslissingen en invarianten uit het transcript")
                    .disabled(!model.canExtract)
                    .symbolEffect(.pulse, isActive: model.promotion == .extracting)
            }
        }
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
                        .buttonStyle(.omaPrimary)
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
            PageTitle(title: "Kies een sessie", subtitle: "Alleen sessies van dit project. Een sessie kan maar in één cel staan.")
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
                Button("Annuleer") { dismiss() }
                    .buttonStyle(.omaSecondary)
                    .keyboardShortcut(.cancelAction)
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
