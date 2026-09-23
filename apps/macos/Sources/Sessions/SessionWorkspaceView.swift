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
                InlineNotice(endNotice, actionTitle: "Dismiss") { model.clearEndNotice() }
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
        .alert("End Session?", isPresented: $showsEndConfirmation) {
            if model.session.session.usesWorktree {
                Button("Merge & End") {
                    Task { await end(merge: true) }
                }
                Button("End Only", role: .destructive) {
                    Task { await end(merge: false) }
                }
            } else {
                Button("End", role: .destructive) {
                    Task { await end(merge: false) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if model.session.session.usesWorktree {
                Text("This session uses its own worktree (\(model.session.session.branch ?? "unknown branch")). Merge & End merges the branch into the main checkout first, then removes the worktree. Uncommitted changes or conflicts keep the session active.")
            } else {
                Text("The tmux session stops and the agent is shut down. Transcript, worktree, and memory are kept.")
            }
        }
        .task {
            await model.loadStatus()
            model.startAutoCheckLoop()
            // Only try to attach if a tmux session can still exist.
            // For an ended session tmux is already gone; an attach would
            // fail immediately with code 256 and fill the detail view with
            // a dead-end "Reconnect" card.
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
            // If the session disappears (for example ended elsewhere) while
            // the terminal tab is open, clear the dead attachment immediately
            // so the ended card appears instead of a fullscreen exited
            // terminal the user cannot leave.
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

    /// Ends only this session. The grid lives at project level, so no other
    /// session can be hit by accident.
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
                Button("Back to Project", systemImage: "chevron.left") { app.closeSession() }
                    .buttonStyle(.omaIcon)
                    .accessibilityLabel("Back to Project")
                    .help("Back to the project cockpit")
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
                        Text(agent?.title ?? "No agent")
                        if let branch = model.session.session.branch {
                            Text(branch).font(.caption.monospaced())
                        }
                        Label(model.runtime, systemImage: "timer")
                        if let status = model.status {
                            Label("\(status.changedFiles.count) files", systemImage: "doc.badge.ellipsis")
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
                    accessibilityLabel: "Tab",
                    title: { $0.title },
                    symbol: { $0.symbol }
                )
                .help("Switch between terminal, changes, memory, and transcript")
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
                .help("Show or hide the inspector (⌥⌘I)")
            OMAIconMenu(symbol: "ellipsis", title: "More actions") {
                Button("Refresh status", systemImage: "arrow.clockwise") { Task { await model.loadStatus() } }
                if model.session.session.isActive {
                    Button("End Session…", systemImage: "stop.circle") { showsEndConfirmation = true }
                }
            }
            if model.hasReviewableCandidates {
                Button("Promote Knowledge", systemImage: "checkmark.seal") { Task { await model.openPreview() } }
                    .buttonStyle(.omaPrimary)
                    .help("Review and apply the extracted knowledge")
            } else if !model.session.session.isActive {
                Button("Extract Knowledge", systemImage: "sparkles") { Task { await model.extractKnowledge() } }
                    .buttonStyle(.omaSecondary)
                    .help("Extract decisions and invariants from the transcript")
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
                StatusBadge(text: "tmux not found", symbol: "exclamationmark.circle", color: OMAColor.attention)
            } else {
                StatusBadge(text: "Completed", symbol: "checkmark.circle", color: OMAColor.quiet)
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
                    Label("Terminal unavailable", systemImage: "terminal")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await terminal.openReportingError(sessionID: model.session.id) } }
                        .buttonStyle(.omaPrimary)
                }
            } else if terminal.occupiedSessionIDs.isEmpty {
                // Intentionally no maxHeight:.infinity (see endedSessionView).
                ProgressView("Connecting terminal…")
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                    .padding(.bottom, 20)
            } else {
                // Single-session detail: one cell, directly in the VStack and
                // intentionally no Grid (see SingleTerminalView): a Grid cell
                // with unbounded height can push the header off-screen.
                // Close is hidden; ending goes through the header action and
                // only affects this session.
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

    /// Ended status for the terminal tab. Intentionally top-aligned without
    /// `frame(maxHeight: .infinity)` and without Spacer(): under the
    /// AppKit split view of `.inspector`, content with unbounded height is
    /// measured, and any greedy height claim makes the VStack explode
    /// (harness-proven: detail became 2210px in a 949 window, header at
    /// y=-513). The "Back to Project" button is an extra escape hatch if
    /// the header is ever covered.
    private var endedSessionView: some View {
        VStack(spacing: 12) {
            Label("Session ended", systemImage: "checkmark.circle")
                .font(.headline)
            Text("The tmux session has stopped and this session is complete. The transcript, worktree (after merging into the main checkout), and memory are kept.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("View transcript", systemImage: "text.bubble") { model.tab = .transcript }
                    .buttonStyle(.omaSecondary)
                Button("Back to Project", systemImage: "chevron.left") { app.closeSession() }
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
            PageTitle(title: "Choose a Session", subtitle: "Only this project's active sessions. A session can occupy only one cell.")
            if let notice {
                InlineNotice(notice)
            }
            // Ended sessions no longer have a tmux session; an attach would
            // fail immediately with code 256. Do not offer them here.
            let available = sessions.filter { $0.session.isActive && !excluded.contains($0.id) }
            if available.isEmpty {
                ContentUnavailableView("No other active sessions", systemImage: "terminal",
                                       description: Text("Start a new session from the project cockpit. Ended sessions no longer have a terminal."))
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
                Button("Cancel") { dismiss() }
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
