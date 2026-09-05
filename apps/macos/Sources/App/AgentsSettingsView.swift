import SwiftUI

struct CustomAgentFormValues: Equatable, Sendable {
    var name = ""
    var binary = ""
    var arguments = ""
    var symbol = "terminal"

    init() {}

    init(agent: CustomAgentDTO) {
        name = agent.name
        binary = agent.binary
        arguments = agent.launchArgs.joined(separator: " ")
        symbol = agent.symbol
    }

    var launchArgs: [String] {
        arguments.split(separator: " ").map(String.init).filter { !$0.isEmpty }
    }

    var error: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Geef de agent een naam."
        }
        if binary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Geef het commando op, bijvoorbeeld opencode."
        }
        if binary.contains(" ") {
            return "Het commando is één programma, zonder spaties. Zet opties bij Argumenten."
        }
        return nil
    }
}

@MainActor
@Observable
final class AgentsSettingsModel {
    var agents: [CustomAgentDTO] = []
    var isLoading = false
    var notice: String?

    func load(client: any DesktopAPI) async {
        isLoading = true
        defer { isLoading = false }
        do {
            agents = try await client.listCustomAgents().sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            notice = nil
        } catch {
            notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func add(client: any DesktopAPI, values: CustomAgentFormValues) async -> String? {
        do {
            _ = try await client.addCustomAgent(
                name: values.name.trimmingCharacters(in: .whitespacesAndNewlines),
                binary: values.binary.trimmingCharacters(in: .whitespacesAndNewlines),
                launchArgs: values.launchArgs,
                symbol: values.symbol
            )
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
                symbol: values.symbol
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

    private var client: any DesktopAPI { app.client }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PanelHeader("Standaardagents", symbol: "sparkles") {
                StatusBadge(text: "Ingebouwd", symbol: "lock.fill", color: OMAColor.quiet)
            }
            VStack(spacing: 8) {
                ForEach(AgentKind.builtins) { agent in
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
                        StatusBadge(text: "Klaar", symbol: "checkmark.circle", color: OMAColor.positive)
                    }
                    .padding(12)
                    .omaCard()
                }
            }

            PanelHeader("Eigen agents", symbol: "terminal") {
                Button("Voeg toe", systemImage: "plus") {
                    draft = CustomAgentFormValues()
                    isAdding = true
                }
                .buttonStyle(.borderedProminent)
                .tint(OMAColor.accent)
                .controlSize(.small)
            }
            Text("Start elk terminalprogramma als agent, zoals opencode of cursor. De prompt wordt als laatste argument meegegeven.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let notice = model.notice {
                InlineNotice(notice)
            }
            if model.isLoading && model.agents.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("Agents laden…")
                    Spacer()
                }
                .padding(.vertical, 8)
            } else if model.agents.isEmpty {
                Text("Nog geen eigen agents. Voeg er een toe om hem in Nieuwe sessie te kiezen.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .omaCard()
            } else {
                VStack(spacing: 8) {
                    ForEach(model.agents) { agent in
                        let kind = AgentKind(rawValue: agent.id)
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
                            Button("Wijzig") {
                                draft = CustomAgentFormValues(agent: agent)
                                editing = agent
                            }
                            .controlSize(.small)
                            Button("Verwijder", role: .destructive) {
                                Task {
                                    await model.remove(client: client, agent: agent)
                                    await app.refreshCustomAgents()
                                }
                            }
                            .controlSize(.small)
                        }
                        .padding(12)
                        .omaCard()
                    }
                }
            }
        }
        .task {
            await model.load(client: client)
        }
        .sheet(isPresented: $isAdding) {
            CustomAgentEditorSheet(title: "Nieuwe agent", values: $draft, presets: true) {
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
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.weight(.semibold))
            if presets {
                HStack(spacing: 8) {
                    Text("Snel:").font(.callout).foregroundStyle(.secondary)
                    Button("Opencode") { values = preset(name: "Opencode", binary: "opencode", arguments: "run", symbol: "terminal.fill") }
                        .controlSize(.small)
                    Button("Cursor") { values = preset(name: "Cursor", binary: "cursor-agent", arguments: "", symbol: "cursorarrow") }
                        .controlSize(.small)
                    Button("Grok") { values = preset(name: "Grok", binary: "grok", arguments: "", symbol: "sparkle") }
                        .controlSize(.small)
                }
            }
            Form {
                TextField("Naam", text: $values.name, prompt: Text("Bijvoorbeeld: Opencode"))
                TextField("Commando", text: $values.binary, prompt: Text("Bijvoorbeeld: opencode"))
                    .font(.body.monospaced())
                TextField("Argumenten (optioneel)", text: $values.arguments, prompt: Text("Bijvoorbeeld: run"))
                    .font(.body.monospaced())
            }
            .formStyle(.grouped)
            VStack(alignment: .leading, spacing: 8) {
                Text("Icoon").font(.callout).foregroundStyle(.secondary)
                AgentSymbolPicker(symbol: $values.symbol)
            }
            Text("Naam en commando zijn verplicht. Argumenten worden vóór de prompt gezet; de prompt komt altijd als laatste argument.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let saveError {
                InlineNotice(saveError)
            }
            HStack {
                Spacer()
                Button("Annuleer") { onCancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Bewaar") {
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
                .buttonStyle(.borderedProminent)
                .tint(OMAColor.accent)
                .disabled(values.error != nil || isSaving)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(OMAColor.canvas)
    }

    private func preset(name: String, binary: String, arguments: String, symbol: String) -> CustomAgentFormValues {
        var v = CustomAgentFormValues()
        v.name = name
        v.binary = binary
        v.arguments = arguments
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
        .accessibilityLabel("Icoon")
    }
}
