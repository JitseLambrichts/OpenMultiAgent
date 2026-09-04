import SwiftUI

/// Newest events load first; older pages are requested from the top sentinel.
struct TranscriptView: View {
    let model: SessionWorkspaceModel

    var body: some View {
        Group {
            if model.events.isEmpty && model.isLoadingTranscript {
                ProgressView("Transcript laden…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.events.isEmpty {
                ContentUnavailableView {
                    Label("Nog geen transcript", systemImage: "text.bubble")
                } description: {
                    Text("Events verschijnen zodra het transcript van deze sessie is ingelezen.")
                } actions: {
                    Button("Vernieuw") { Task { await model.loadNewestTranscript() } }
                }
            } else {
                ScrollViewReader { proxy in
                    List {
                        if model.nextCursor != nil {
                            HStack {
                                Spacer()
                                Button {
                                    Task { await model.loadOlderTranscript() }
                                } label: {
                                    if model.isLoadingTranscript {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Label("Laad oudere events", systemImage: "arrow.up")
                                    }
                                }
                                .buttonStyle(.bordered)
                                .disabled(!model.canLoadOlderTranscript)
                                Spacer()
                            }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .onAppear {
                                Task { await model.loadOlderTranscript() }
                            }
                        }
                        ForEach(model.events) { event in
                            TranscriptEventRow(event: event)
                                .id(event.identity)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onAppear {
                        if let last = model.events.last {
                            proxy.scrollTo(last.identity, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .transaction { $0.animation = nil }
        .task {
            if !model.hasLoadedTranscript { await model.loadNewestTranscript() }
        }
    }
}

struct TranscriptEventRow: View {
    let event: TranscriptEventDTO

    private var role: (text: String, symbol: String, color: Color) {
        switch event.role {
        case "user": ("Gebruiker", "person", OMAColor.accent)
        case "assistant": ("Agent", "sparkles", OMAColor.attention)
        default: ("Systeem", "gearshape", Color.secondary)
        }
    }

    private var isTool: Bool { event.kind == "tool_use" || event.kind == "tool_result" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(role.text, systemImage: role.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(role.color)
                if isTool {
                    Label(event.toolName ?? event.kind, systemImage: "wrench.and.screwdriver")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if event.kind == "thinking" {
                    Label("Redenering", systemImage: "brain")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let text = event.text, !text.isEmpty {
                Text(text)
                    .font(isTool ? .callout.monospaced() : .callout)
                    .lineLimit(isTool ? 12 : 40)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("(geen tekst)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
