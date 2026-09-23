import SwiftUI

/// One sheet for every entry point: dashboard card, cockpit toolbar, Command-N.
/// When several projects are offered, the sheet adds a project picker.
struct NewSessionSheet: View {
    let projects: [ProjectDTO]
    let agents: [AgentKind]
    let displayName: (AgentKind) -> String
    let symbol: (AgentKind) -> String
    let onCreate: (NewSessionRequest) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedProjectID: String?
    @State private var title = ""
    @State private var prompt = ""
    @State private var agent: AgentKind
    @State private var usesWorktree = true
    @State private var isSubmitting = false
    @FocusState private var titleFocused: Bool

    init(projects: [ProjectDTO], preselected: ProjectDTO?, agents: [AgentKind] = AgentKind.allCases, displayName: @escaping (AgentKind) -> String = { $0.title }, symbol: @escaping (AgentKind) -> String = { $0.symbol }, onCreate: @escaping (NewSessionRequest) async -> Void) {
        self.projects = projects
        self.agents = agents.isEmpty ? AgentKind.allCases : agents
        self.displayName = displayName
        self.symbol = symbol
        self.onCreate = onCreate
        _selectedProjectID = State(initialValue: preselected?.id ?? projects.first?.id)
        _agent = State(initialValue: (agents.isEmpty ? AgentKind.allCases : agents).first ?? .claude)
    }

    init(project: ProjectDTO, agents: [AgentKind] = AgentKind.allCases, displayName: @escaping (AgentKind) -> String = { $0.title }, symbol: @escaping (AgentKind) -> String = { $0.symbol }, onCreate: @escaping (NewSessionRequest) async -> Void) {
        self.init(projects: [project], preselected: project, agents: agents, displayName: displayName, symbol: symbol, onCreate: onCreate)
    }

    private var selectedProject: ProjectDTO? {
        projects.first { $0.id == selectedProjectID }
    }

    private var canSubmit: Bool {
        selectedProject != nil
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            PageTitle(
                title: "New Session",
                subtitle: projects.count == 1 ? selectedProject?.displayName : "Start an agent in a project, optionally in its own worktree."
            )

            Form {
                if projects.count > 1 {
                    Picker("Project", selection: $selectedProjectID) {
                        ForEach(projects) { project in
                            Text(project.displayName).tag(Optional(project.id))
                        }
                    }
                }

                TextField("Title", text: $title, prompt: Text("For example: Build M4 dashboard"))
                    .focused($titleFocused)

                Picker("Agent", selection: $agent) {
                    ForEach(agents) { agent in
                        Label(displayName(agent), systemImage: symbol(agent)).tag(agent)
                    }
                }

                Toggle("Create an isolated Git worktree", isOn: $usesWorktree)
                    .disabled(agent == .terminal)

                if agent != .terminal {
                    TextField("Start prompt (optional)", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)

            HStack {
                if projects.isEmpty {
                    Label("Add a project first.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.omaSecondary)
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    if isSubmitting {
                        Label("Starting session…", systemImage: "progress.indicator")
                            .symbolEffect(.variableColor.iterative, isActive: isSubmitting)
                } else if agent == .terminal {
                    Text("Start a bare shell in this project, without an agent or worktree.")
                        .foregroundStyle(.secondary)
                } else {
                        Text("Create Session")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.omaPrimary)
                .disabled(!canSubmit)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(OMAColor.canvas)
        .onAppear { titleFocused = true }
    }

    private func submit() {
        guard let selectedProject, canSubmit else { return }
        let isTerminal = agent == .terminal
        let request = NewSessionRequest(
            repoPath: selectedProject.repoPath,
            agent: agent,
            usesWorktree: isTerminal ? false : usesWorktree,
            title: title.nilIfBlank,
            prompt: isTerminal ? nil : prompt.nilIfBlank
        )
        isSubmitting = true
        Task {
            await onCreate(request)
            isSubmitting = false
            dismiss()
        }
    }
}

extension String {
    var nilIfBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
