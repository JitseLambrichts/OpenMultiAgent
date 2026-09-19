import SwiftUI

struct SessionWorkspaceView: View {
    @State private var model: SessionWorkspaceModel
    @State private var terminal: TerminalWorkspaceModel
    @State private var showsEndConfirmation = false
    @State private var diffTarget: FileDiffTarget?
    let app: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(session: SessionViewDTO, app: AppModel) {
        _model = State(initialValue: SessionWorkspaceModel(session: session, client: app.client))
        _terminal = State(initialValue: TerminalWorkspaceModel(factory: SidecarTerminalFactory(client: app.client)))
        self.app = app
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let endNotice = model.endNotice {
                InlineNotice(endNotice, actionTitle: "Sluiten") { model.clearEndNotice() }
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            } else if let notice = model.notice {
                InlineNotice(notice)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            content
        }
        .background(OMAColor.canvas)
        .inspector(isPresented: Binding(get: { app.isInspectorVisible }, set: { app.isInspectorVisible = $0 })) {
            SessionInspector(
                session: model.session,
                status: model.status,
                symbolForAgent: { app.symbol(forAgentID: $0) }
            ) { file in
                if let projectID = currentProjectID {
                    diffTarget = FileDiffTarget(
                        projectID: projectID,
                        sessionID: model.session.id,
                        sessionTitle: model.session.session.displayTitle,
                        file: file
                    )
                }
            }
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
        .sheet(item: $diffTarget) { target in
            FileDiffSheet(target: target, client: app.client) { opened in
                app.openProjectEditor(sessionID: opened.sessionID, path: opened.file.path)
            }
        }
        .alert("Sessie beëindigen?", isPresented: $showsEndConfirmation) {
            if model.session.session.usesWorktree {
                Button("Merge + beëindig") {
                    Task { await end(merge: true) }
                }
                Button("Alleen beëindigen", role: .destructive) {
                    Task { await end(merge: false) }
                }
            } else {
                Button("Beëindig", role: .destructive) {
                    Task { await end(merge: false) }
                }
            }
            Button("Annuleer", role: .cancel) {}
        } message: {
            if model.session.session.usesWorktree {
                Text("Deze sessie werkt in een eigen worktree (\(model.session.session.branch ?? "onbekende branch")). “Merge + beëindig” voegt de branch eerst samen met de hoofdcheckout en ruimt daarna de worktree op. Bij niet-gecommitte wijzigingen of conflicten blijft de sessie actief.")
            } else {
                Text("De tmux-sessie stopt en de agent wordt afgesloten. Transcript, worktree en geheugen blijven bewaard.")
            }
        }
        .task {
            await model.loadStatus()
            model.startAutoCheckLoop()
            // Alleen een attach proberen als er nog een tmux-sessie kán zijn.
            // Voor een beëindigde sessie is tmux al opgeruimd; een attach zou
            // direct met code 256 falen en de detailview vullen met een
            // doodlopende "Verbind opnieuw"-kaart.
            if model.canAttachTerminal {
                terminal.requestLayout(.single)
                await terminal.openReportingError(sessionID: model.session.id)
            }
        }
        .onDisappear {
            Task { await model.stopAutoCheckLoop() }
        }
        .onChange(of: app.reconciliationTick) { _, _ in Task { await model.loadStatus() } }
        .onChange(of: model.session.session.isActive) { _, active in
            // Valt de sessie weg (bv. elders beëindigd) terwijl de terminaltab
            // open staat, ruim de dode koppeling dan meteen op zodat de
            // beëindigd-kaart verschijnt in plaats van een fullscreen
            // exited-terminal waar de gebruiker niet meer uit kan.
            if !active {
                terminal.close(sessionID: model.session.id)
                terminal.unfocus()
            }
        }
        .onChange(of: model.tab) { _, tab in
            if tab == .transcript && !model.hasLoadedTranscript {
                Task { await model.loadNewestTranscript() }
            }
        }
    }

    // MARK: Lifecycle

    /// Beëindigt alleen deze sessie. De grid leeft op projectniveau, dus er is
    /// geen andere sessie die per ongeluk geraakt kan worden.
    private func end(merge: Bool) async {
        let ok = await model.endSession(merge: merge)
        guard ok else { return }
        terminal.unfocus()
        terminal.close(sessionID: model.session.id)
        app.selectedSession = model.session
        app.reconcile()
    }

    private var currentProjectID: String? {
        app.selectedProject?.id
            ?? app.projects.project(forRepoPath: model.session.session.repoPath)?.id
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                let agent = model.session.currentAgent
                Button("Terug naar project", systemImage: "chevron.left") { app.closeSession() }
                    .buttonStyle(.omaIcon)
                    .accessibilityLabel("Terug naar project")
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
            if !model.canAttachTerminal {
                endedSessionView
            } else if let error = terminal.errorMessage {
                ContentUnavailableView {
                    Label("Terminal niet beschikbaar", systemImage: "terminal")
                } description: {
                    Text(error)
                } actions: {
                    Button("Probeer opnieuw") { Task { await terminal.openReportingError(sessionID: model.session.id) } }
                        .buttonStyle(.omaPrimary)
                }
            } else if terminal.occupiedSessionIDs.isEmpty {
                // Bewust géén maxHeight:.infinity (zie endedSessionView).
                ProgressView("Terminal verbinden…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.bottom, 20)
            } else {
                // Single-sessie detail: één cel, direct in de VStack en bewust
                // géén Grid (zie SingleTerminalView): een Grid-cel met
                // ongelimiteerde hoogte kan de header buiten beeld duwen.
                // Sluiten is verborgen; beëindigen gaat via de header-actie en
                // raakt alleen deze sessie.
                SingleTerminalView(
                    model: terminal,
                    sessionID: model.session.id,
                    title: model.session.session.displayTitle,
                    sessionActive: model.session.session.isActive
                )
            }
        case .changes:
            ChangesView(
                status: model.status,
                isLoading: model.isLoadingStatus,
                notice: model.notice,
                projectID: currentProjectID,
                session: model.session
            ) { target in
                diffTarget = target
            } onRefresh: {
                Task { await model.loadStatus() }
            }
        case .memory:
            MemorySearchView(client: app.client, scopeRepoPath: model.session.session.repoPath,
                             projects: app.projects.projects, app: app)
        case .transcript:
            TranscriptView(model: model)
        }
    }

    /// Beëindigd-status voor de terminaltab. Bewust top-aligned zónder
    /// `frame(maxHeight: .infinity)` en zónder Spacer(): onder de
    /// AppKit-splitview van `.inspector` wordt content met ongelimiteerde
    /// hoogte gemeten, en elke gulzige hoogteclaim laat de VStack exploderen
    /// (harness-bewezen: detail werd 2210px in een venster van 949, header op
    /// y=-513). De "Terug naar project"-knop is een extra vluchtweg voor het
    /// geval de header ooit afgedekt zou worden.
    private var endedSessionView: some View {
        VStack(spacing: 12) {
            Label("Sessie beëindigd", systemImage: "checkmark.circle")
                .font(.headline)
            Text("De tmux-sessie is gestopt en de sessie staat op Afgerond. Het transcript, de worktree (na merge in de hoofdcheckout) en het geheugen blijven bewaard.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Bekijk transcript", systemImage: "text.bubble") { model.tab = .transcript }
                    .buttonStyle(.omaSecondary)
                Button("Terug naar project", systemImage: "chevron.left") { app.closeSession() }
                    .buttonStyle(.omaPrimary)
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 560)
        .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .top)
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
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
            PageTitle(title: "Kies een sessie", subtitle: "Alleen actieve sessies van dit project. Een sessie kan maar in één cel staan.")
            if let notice {
                InlineNotice(notice)
            }
            // Beëindigde sessies hebben geen tmux-sessie meer; een attach zou
            // direct met code 256 falen. Bied ze hier niet aan.
            let available = sessions.filter { $0.session.isActive && !excluded.contains($0.id) }
            if available.isEmpty {
                ContentUnavailableView("Geen andere actieve sessies", systemImage: "terminal",
                                       description: Text("Start een nieuwe sessie vanuit de projectcockpit. Beëindigde sessies hebben geen terminal meer."))
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
