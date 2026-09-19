import SwiftUI

/// Every primary workflow is reachable from the menu bar. Shortcuts are bound
/// here exactly once; views react to `AppModel.pendingCommand`.
struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nieuwe sessie…") { model.request(.newSession) }
                .keyboardShortcut("n", modifiers: .command)
            Button("Voeg project toe…") { model.request(.addProject) }
                .keyboardShortcut("o", modifiers: .command)
            Divider()
            Button("Nieuw venster") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }

        CommandMenu("Sessie") {
            Button("Zoek in geheugen") { model.request(.search) }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            ForEach(TerminalLayout.allCases) { layout in
                Button("Indeling: \(layout.title)") { model.request(.terminalLayout(layout)) }
                    .keyboardShortcut(layout.shortcutKey, modifiers: .control)
            }
        }

        CommandGroup(after: .saveItem) {
            Button("Bewaar") { model.request(.saveEditor) }
                .keyboardShortcut("s", modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            Button(model.isInspectorVisible ? "Verberg inspector" : "Toon inspector") {
                model.isInspectorVisible.toggle()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

extension TerminalLayout {
    var shortcutKey: KeyEquivalent {
        switch self {
        case .single: "1"
        case .horizontal: "2"
        case .twoByTwo: "3"
        case .adaptive: "4"
        }
    }
}
