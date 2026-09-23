import SwiftUI

/// Newest events load first; older pages are requested from the top sentinel.
struct TranscriptView: View {
    let model: SessionWorkspaceModel

    var body: some View {
        Group {
            if model.events.isEmpty && model.isLoadingTranscript {
                ProgressView("Loading transcript…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.events.isEmpty {
                ContentUnavailableView {
                    Label("No transcript yet", systemImage: "text.bubble")
                } description: {
                    Text("Events appear once this session's transcript has been ingested.")
                } actions: {
                    Button("Refresh") { Task { await model.loadNewestTranscript() } }
                        .buttonStyle(.omaSecondary)
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
                                        Label("Load older events", systemImage: "arrow.up")
                                    }
                                }
                                .buttonStyle(.omaSecondary)
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
        case "user": ("User", "person", OMAColor.accent)
        case "assistant": ("Agent", "sparkles", OMAColor.attention)
        default: ("System", "gearshape", Color.secondary)
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
                    Label("Reasoning", systemImage: "brain")
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
                Text("(no text)")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OMAColor.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
