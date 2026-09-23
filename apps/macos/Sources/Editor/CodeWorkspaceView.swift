import SwiftUI

struct CodeWorkspaceView: View {
    @Bindable var model: CodeWorkspaceModel
    let sessions: [SessionViewDTO]
    var terminals: TerminalWorkspaceModel?
    var onOpenTerminals: () -> Void = {}
    var onStartShell: () -> Void = {}

    @State private var isTerminalVisible = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 28)
                .padding(.bottom, 12)
            if let notice = model.notice {
                InlineNotice(notice)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 12)
            }
            VSplitView {
                HSplitView {
                    FileTreeView(nodes: model.tree, selectedPath: model.selectedPath) { path in
                        Task { await model.openFile(path) }
                    }
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 360)
                    editorPane
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                }
                if isTerminalVisible {
                    terminalStrip
                        .frame(minHeight: 120, idealHeight: 200)
                }
            }
        }
        .background(OMAColor.canvas)
        .task { await model.loadTree() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            rootMenu
            Spacer()
            if let selected = model.selectedBuffer {
                Text(selected.path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if selected.isDirty {
                    Text("Unsaved")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OMAColor.attention)
                }
            }
            Button("Save", systemImage: "square.and.arrow.down") {
                Task { await model.saveSelected() }
            }
            .buttonStyle(.omaIcon)
            .disabled(!model.selectedIsDirty || model.isSaving)
            .help("Save the current file (⌘S)")
            Button(isTerminalVisible ? "Hide Terminal" : "Show Terminal", systemImage: "terminal") {
                isTerminalVisible.toggle()
            }
            .buttonStyle(.omaIcon)
            .help("Show or hide the terminal strip")
        }
    }

    private var rootMenu: some View {
        Menu {
            Button("Project") { Task { await model.selectRoot(.project) } }
            ForEach(sessions.filter { $0.session.isActive }) { session in
                Button(session.session.displayTitle) {
                    Task { await model.selectRoot(.session(id: session.id)) }
                }
            }
        } label: {
            Label(rootTitle, systemImage: model.root == .project ? "shippingbox" : "leaf")
                .font(.subheadline.weight(.medium))
        }
        .menuStyle(.borderlessButton)
        .help("Choose the project checkout or a session worktree")
        .accessibilityLabel("Editor source")
    }

    private var rootTitle: String {
        switch model.root {
        case .project:
            return model.project.displayName
        case .session(let id):
            return sessions.first { $0.id == id }?.session.displayTitle ?? "Session"
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        VStack(spacing: 0) {
            if model.buffers.count > 1 {
                bufferTabs
            }
            if let path = model.selectedPath, model.selectedBuffer != nil {
                SourceEditorView(
                    text: Binding(
                        get: { model.buffers.first { $0.path == path }?.content ?? "" },
                        set: { model.updateContent($0, for: path) }
                    ),
                    path: path,
                    onSave: { Task { await model.saveSelected() } }
                )
                .id(path)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading {
                ProgressView("Loading files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No file open",
                    systemImage: "doc.text",
                    description: Text("Choose a file in the tree on the left.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(OMAColor.surface)
    }

    private var bufferTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.buffers) { buffer in
                    Button {
                        model.selectedPath = buffer.path
                    } label: {
                        HStack(spacing: 6) {
                            Text(buffer.name)
                                .font(.caption.monospaced())
                            if buffer.isDirty {
                                Circle().fill(OMAColor.attention).frame(width: 6, height: 6)
                            }
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .onTapGesture { model.closeBuffer(buffer.path) }
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 28)
                        .background(buffer.path == model.selectedPath ? OMAColor.elevated : .clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(buffer.path)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(OMAColor.canvas)
    }

    @ViewBuilder
    private var terminalStrip: some View {
        switch model.root {
        case .session(let id):
            if let terminals, let session = sessions.first(where: { $0.id == id }), session.session.isActive {
                CompactTerminalStrip(model: terminals, session: session)
                    .task {
                        if !terminals.isOpen(id) {
                            await terminals.openReportingError(sessionID: id)
                        }
                    }
            } else {
                terminalPlaceholder(
                    "This session has no active terminal.",
                    actionTitle: "Open Terminals",
                    action: onOpenTerminals
                )
            }
        case .project:
            terminalPlaceholder(
                "Commands run in a bare shell or an agent session. Start one, or switch to the Terminals tab.",
                actionTitle: "Start Shell",
                action: onStartShell
            )
        }
    }

    private func terminalPlaceholder(_ message: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(actionTitle, action: action)
                .buttonStyle(.omaSecondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(OMAColor.surface)
    }
}

private struct CompactTerminalStrip: View {
    let model: TerminalWorkspaceModel
    let session: SessionViewDTO

    var body: some View {
        Group {
            if let controller = model.controller(for: session.id) as? TerminalController {
                TerminalCellView(
                    model: model,
                    controller: controller,
                    sessionID: session.id,
                    isFocused: false,
                    title: session.session.displayTitle,
                    sessionActive: session.session.isActive,
                    allowFocus: false,
                    allowClose: false,
                    onOpenDetail: nil
                )
            } else if let error = model.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(16)
            } else {
                ProgressView("Connecting terminal…")
                    .frame(maxWidth: .infinity, minHeight: 88)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(OMAColor.canvas)
        .clipped()
    }
}