import SwiftUI

struct CustomAgentFormValues: Equatable, Sendable {
    var name = ""
    var binary = ""
    var arguments = ""
    var headlessArguments = ""
    var symbol = "terminal"
    var systemPrompt = ""

    init() {}

    init(agent: CustomAgentDTO, systemPrompt: String = "") {
        name = agent.name
        binary = agent.binary
        arguments = agent.launchArgs.joined(separator: " ")
        headlessArguments = agent.headlessArgs.joined(separator: " ")
        symbol = agent.symbol
        self.systemPrompt = systemPrompt
    }

    var launchArgs: [String] {
        Self.split(arguments)
    }

    var headlessArgs: [String] {
        Self.split(headlessArguments)
    }

    private static func split(_ value: String) -> [String] {
        value.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    var error: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give the agent a name."
        }
        if binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Enter the command, for example opencode."
        }
        if binary.contains(" ") {
            return "The command is a single program, with no spaces. Put options in Arguments."
        }
        return nil
    }
}

@MainActor
@Observable
final class AgentsSettingsModel {
    var agents: [CustomAgentDTO] = []
    var systemPrompts: [String: String] = [:]
    var isLoading = false
    var notice: String?

    func load(client: any DesktopAPI) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetchedAgents = try await client.listCustomAgents()
            agents = fetchedAgents.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            do {
                let fetchedPrompts = try await client.listAgentSystemPrompts()
                systemPrompts = Dictionary(
                    uniqueKeysWithValues: fetchedPrompts.map { ($0.agent, $0.systemPrompt) }
                )
                notice = nil
            } catch {
                // Older sidecars do not know the prompt route yet; still show
                // the agents instead of hiding everything.
                systemPrompts = [:]
                notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func prompt(for agentID: String) -> String {
        systemPrompts[agentID] ?? ""
    }

    func add(client: any DesktopAPI, values: CustomAgentFormValues) async -> String? {
        do {
            let created = try await client.addCustomAgent(
                name: values.name.trimmingCharacters(in: .whitespacesAndNewlines),
                binary: values.binary.trimmingCharacters(in: .whitespacesAndNewlines),
                launchArgs: values.launchArgs,
                headlessArgs: values.headlessArgs,
                symbol: values.symbol
            )
            let prompt = values.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !prompt.isEmpty {
                try await client.setAgentSystemPrompt(agent: created.id, systemPrompt: prompt)
            }
            await load(client: client)
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            notice = message
            return message
        }
    }

    func update(client: any DesktopAPI, id: String, values: CustomAgentFormValues) async -> String? {
        do {
            _ = try await client.updateCustomAgent(
                id: id,
                name: values.name.trimmingCharacters(in: .whitespacesAndNewlines),
                binary: values.binary.trimmingCharacters(in: .whitespacesAndNewlines),
                launchArgs: values.launchArgs,
                headlessArgs: values.headlessArgs,
                symbol: values.symbol
            )
            try await client.setAgentSystemPrompt(
                agent: id,
                systemPrompt: values.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await load(client: client)
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            notice = message
            return message
        }
    }

    func saveSystemPrompt(client: any DesktopAPI, agentID: String, prompt: String) async -> String? {
        do {
            try await client.setAgentSystemPrompt(
                agent: agentID,
                systemPrompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await load(client: client)
            return nil
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            notice = message
            return message
        }
    }

    func remove(client: any DesktopAPI, agent: CustomAgentDTO) async {
        do {
            try await client.removeCustomAgent(id: agent.id)
            // Clearing the prompt is best-effort: a missing route must never
            // block deletion.
            try? await client.setAgentSystemPrompt(agent: agent.id, systemPrompt: "")
            await load(client: client)
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct AgentsSettingsView: View {
    let app: AppModel
    @State private var model = AgentsSettingsModel()
    @State private var isAdding = false
    @State private var editing: CustomAgentDTO?
    @State private var draft = CustomAgentFormValues()
    @State private var expandedPrompts: Set<String> = []

    private var client: any DesktopAPI { app.client }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader("Built-in agents", symbol: "sparkles") {
                StatusBadge(text: "Built-in", symbol: "lock.fill", color: OMAColor.quiet)
            }
            Text("Give each agent its own system prompt. It is included in every new session; on a switch it comes before the Handoff Brief.")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 8) {
                ForEach(AgentKind.builtins) { agent in
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 12) {
                            Image(systemName: agent.symbol)
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(agent.tint)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.title).font(.body.weight(.medium))
                                Text(binaryName(for: agent))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !model.prompt(for: agent.rawValue).isEmpty {
                                StatusBadge(text: "Custom prompt", symbol: "text.quote", color: OMAColor.accent)
                            } else {
                                StatusBadge(text: "Ready", symbol: "checkmark.circle", color: OMAColor.positive)
                            }
                            Button(expandedPrompts.contains(agent.rawValue) ? "Hide" : "Prompt") {
                                toggle(agent.rawValue)
                            }
                            .controlSize(.small)
                        }
                        .padding(12)
                        if expandedPrompts.contains(agent.rawValue) {
                            AgentSystemPromptEditor(
                                prompt: model.prompt(for: agent.rawValue),
                                hint: "For \(agent.title). Leave empty for the default behavior.",
                                onSave: { prompt in
                                    await model.saveSystemPrompt(client: client, agentID: agent.rawValue, prompt: prompt)
                                }
                            )
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                    .omaCard()
                }
            }

            PanelHeader("Custom agents", symbol: "terminal") {
                Button("Add", systemImage: "plus") {
                    draft = CustomAgentFormValues()
                    isAdding = true
                }
                .buttonStyle(.omaPrimary)
                .controlSize(.small)
            }
            Text("Launch any terminal program as an agent, such as OpenCode or Cursor. Leave arguments empty for the interactive TUI; a one-shot such as run closes the terminal immediately.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let notice = model.notice {
                InlineNotice(notice)
            }
            if model.isLoading && model.agents.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Loading agents…")
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if model.agents.isEmpty {
                Text("No custom agents yet. Add one to choose it in New Session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .omaCard()
            } else {
                VStack(spacing: 8) {
                    ForEach(model.agents) { agent in
                        let kind = AgentKind(rawValue: agent.id)
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 12) {
                                Image(systemName: agent.symbol)
                                    .symbolRenderingMode(.hierarchical)
                                    .foregroundStyle(kind.tint)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name).font(.body.weight(.medium))
                                    Text(commandPreview(for: agent))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                if !model.prompt(for: agent.id).isEmpty {
                                    StatusBadge(text: "Custom prompt", symbol: "text.quote", color: OMAColor.accent)
                                }
                                Button(expandedPrompts.contains(agent.id) ? "Hide" : "Prompt") {
                                    toggle(agent.id)
                                }
                                .controlSize(.small)
                                Button("Edit") {
                                    draft = CustomAgentFormValues(agent: agent, systemPrompt: model.prompt(for: agent.id))
                                    editing = agent
                                }
                                .controlSize(.small)
                                Button("Delete", role: .destructive) {
                                    Task {
                                        await model.remove(client: client, agent: agent)
                                        await app.refreshCustomAgents()
                                    }
                                }
                                .controlSize(.small)
                            }
                            .padding(12)
                            if expandedPrompts.contains(agent.id) {
                                AgentSystemPromptEditor(
                                    prompt: model.prompt(for: agent.id),
                                    hint: "Use {{system}} in Arguments to choose the placement; without a placeholder the prompt is prepended.",
                                    onSave: { prompt in
                                        await model.saveSystemPrompt(client: client, agentID: agent.id, prompt: prompt)
                                    }
                                )
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            }
                        }
                        .omaCard()
                    }
                }
            }
        }
        .task {
            await model.load(client: client)
        }
        .sheet(isPresented: $isAdding) {
            CustomAgentEditorSheet(title: "New agent", values: $draft, presets: true) {
                isAdding = false
            } onSave: { values in
                if let message = await model.add(client: client, values: values) {
                    return message
                }
                isAdding = false
                await app.refreshCustomAgents()
                return nil
            }
        }
        .sheet(item: $editing) { agent in
            CustomAgentEditorSheet(title: agent.name, values: $draft, presets: false) {
                editing = nil
            } onSave: { values in
                if let message = await model.update(client: client, id: agent.id, values: values) {
                    return message
                }
                editing = nil
                await app.refreshCustomAgents()
                return nil
            }
        }
    }

    private func toggle(_ id: String) {
        if expandedPrompts.contains(id) {
            expandedPrompts.remove(id)
        } else {
            expandedPrompts.insert(id)
        }
    }

    private func binaryName(for agent: AgentKind) -> String {
        switch agent.rawValue {
        case "claude": "claude"
        case "codex": "codex"
        case "gemini": "gemini"
        default: agent.rawValue
        }
    }

    private func commandPreview(for agent: CustomAgentDTO) -> String {
        ([agent.binary] + agent.launchArgs).joined(separator: " ")
    }
}

struct AgentSystemPromptEditor: View {
    let prompt: String
    let hint: String
    /// Returns the failure message, or nil when saving succeeded.
    let onSave: (String) async -> String?

    @State private var draft: String = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var savedFlash = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("System prompt")
                .font(.callout.weight(.medium))
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 90, maxHeight: 180)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(OMAColor.elevated)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(.secondary.opacity(0.25))
                }
                .accessibilityLabel("System prompt")
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text("\(draft.trimmingCharacters(in: .whitespacesAndNewlines).count) characters")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if savedFlash {
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(OMAColor.positive)
                }
                Spacer()
                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Clear") {
                        draft = ""
                        save()
                    }
                    .controlSize(.small)
                    .disabled(isSaving)
                }
                Button(isSaving ? "Saving…" : "Save") {
                    save()
                }
                .controlSize(.small)
                .buttonStyle(.omaPrimary)
                .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines) == prompt.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let error {
                InlineNotice(error)
            }
        }
        .onAppear {
            if draft.isEmpty { draft = prompt }
        }
        .onChange(of: prompt) { _, newValue in
            if !isSaving { draft = newValue }
        }
    }

    private func save() {
        error = nil
        savedFlash = false
        isSaving = true
        let value = draft
        Task {
            if let message = await onSave(value) {
                isSaving = false
                error = message
            } else {
                isSaving = false
                savedFlash = true
            }
        }
    }
}

struct CustomAgentEditorSheet: View {
    let title: String
    @Binding var values: CustomAgentFormValues
    let presets: Bool
    let onCancel: () -> Void
    /// Returns the failure message, or nil when saving succeeded.
    let onSave: (CustomAgentFormValues) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var saveError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(title).font(.title2.weight(.semibold))
                if presets {
                    HStack(spacing: 8) {
                        Text("Quick:").font(.callout).foregroundStyle(.secondary)
                        Button("Opencode") {
                            values = preset(
                                name: "Opencode",
                                binary: "opencode",
                                arguments: "",
                                headlessArguments: "run --format json --auto -- {{prompt}}",
                                symbol: "terminal.fill"
                            )
                        }
                        .controlSize(.small)
                        Button("Cursor") {
                            values = preset(
                                name: "Cursor",
                                binary: "cursor-agent",
                                arguments: "",
                                headlessArguments: "-p --output-format json {{prompt}}",
                                symbol: "cursorarrow"
                            )
                        }
                        .controlSize(.small)
                        Button("Grok") {
                            values = preset(
                                name: "Grok",
                                binary: "grok",
                                arguments: "",
                                headlessArguments: "",
                                symbol: "sparkle"
                            )
                        }
                        .controlSize(.small)
                    }
                }
                Form {
                    TextField("Name", text: $values.name, prompt: Text("For example: OpenCode"))
                    TextField("Command", text: $values.binary, prompt: Text("For example: opencode"))
                        .font(.body.monospaced())
                    TextField("Arguments (optional)", text: $values.arguments, prompt: Text("Leave empty for the TUI"))
                        .font(.body.monospaced())
                    TextField(
                        "Headless arguments (optional)",
                        text: $values.headlessArguments,
                        prompt: Text("For example: -p --output-format json {{prompt}}")
                    )
                    .font(.body.monospaced())
                }
                .formStyle(.grouped)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Icon").font(.callout).foregroundStyle(.secondary)
                    AgentSymbolPicker(symbol: $values.symbol)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("System prompt (optional)").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: $values.systemPrompt)
                        .font(.body)
                        .frame(minHeight: 90, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(OMAColor.elevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(.secondary.opacity(0.25))
                        }
                        .accessibilityLabel("System prompt")
                    Text("Use {{system}} in Arguments to choose the placement; without a placeholder the prompt is prepended.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("Name and command are required. Leave arguments empty to start the interactive TUI. Extra arguments come before an optional start prompt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Headless arguments are used for knowledge extraction: the one-shot, non-interactive run that must return JSON. Use {{prompt}} to place the prompt; without a placeholder it is appended.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let saveError {
                    InlineNotice(saveError)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { onCancel(); dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        guard values.error == nil else { saveError = values.error; return }
                        isSaving = true
                        Task {
                            if let message = await onSave(values) {
                                isSaving = false
                                saveError = message
                            } else {
                                isSaving = false
                                saveError = nil
                                dismiss()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.omaPrimary)
                    .disabled(values.error != nil || isSaving)
                }
            }
            .padding(24)
        }
        .frame(width: 520, height: 640)
        .background(OMAColor.canvas)
    }

    private func preset(
        name: String,
        binary: String,
        arguments: String,
        headlessArguments: String,
        symbol: String
    ) -> CustomAgentFormValues {
        var v = CustomAgentFormValues()
        v.name = name
        v.binary = binary
        v.arguments = arguments
        v.headlessArguments = headlessArguments
        v.symbol = symbol
        return v
    }
}

private struct AgentSymbolPicker: View {
    @Binding var symbol: String

    private var choices: [String] {
        if Self.catalog.contains(symbol) { return Self.catalog }
        return [symbol] + Self.catalog
    }

    private static let catalog = [
        "terminal", "terminal.fill", "cursorarrow", "sparkle", "sparkles",
        "chevron.left.forwardslash.chevron.right", "curlybraces",
        "laptopcomputer", "cpu", "brain.head.profile", "bolt", "cube",
        "hammer", "wrench.and.screwdriver", "command", "keyboard",
        "globe", "moon.stars", "wand.and.stars", "ant", "paperplane",
        "bubble.left.and.bubble.right", "gearshape",
    ]

    private let columns = Array(repeating: GridItem(.fixed(34), spacing: 6), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(choices, id: \.self) { name in
                Button {
                    symbol = name
                } label: {
                    Image(systemName: name)
                        .font(.body)
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 34, height: 34)
                        .foregroundStyle(symbol == name ? OMAColor.accent : .secondary)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(symbol == name ? OMAColor.accent.opacity(0.16) : OMAColor.elevated)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(symbol == name ? OMAColor.accent.opacity(0.45) : .clear)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name.replacingOccurrences(of: ".", with: " "))
                .accessibilityAddTraits(symbol == name ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Icon")
    }
}
