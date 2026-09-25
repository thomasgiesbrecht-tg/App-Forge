import SwiftUI

/// Ideen der geöffneten App – rechte Seitenleiste. Ideen werden nur gesammelt und vom Ideen-Agenten eingeordnet.
struct IdeasPanel: View {
    @Environment(AppStore.self) private var store
    @State private var draft = ""
    @State private var showClosed = false
    @FocusState private var focused: Bool

    private var projectID: String? { store.selectedProject }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let projectID {
                input(projectID)
                list(projectID)
            } else {
                ContentUnavailableView {
                    Label("Kein Projekt", systemImage: "lightbulb")
                } description: {
                    Text("Öffne links eine App, um ihre Ideen zu sehen.")
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    private func input(_ projectID: String) -> some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Neue Idee …", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .focused($focused)
                .onSubmit { add(projectID) }
            Button { add(projectID) } label: { Image(systemName: "arrow.up") }
                .buttonStyle(IconButtonStyle(size: 24, filled: draft.isEmpty ? nil : Theme.accent))
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.lift))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }

    private func add(_ projectID: String) {
        guard store.ideas.add(text: draft, projectID: projectID, source: .mac) != nil else { return }
        draft = ""
    }

    private func list(_ projectID: String) -> some View {
        let all = store.ideas.ideas(for: projectID)
        let open = all.filter { $0.status == .open }
        let closed = all.filter { $0.status != .open }
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if all.isEmpty {
                    Text("Noch keine Ideen. Schreib sie hier oder unterwegs auf dem iPhone auf – der Ideen-Agent ordnet sie ein, ohne etwas umzusetzen.")
                        .font(Theme.Fonts.sans(11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 6)
                }
                ForEach(open) { IdeaRow(idea: $0) }
                if !closed.isEmpty {
                    Button {
                        withAnimation(Theme.Motion.spring) { showClosed.toggle() }
                    } label: {
                        Label("\(closed.count) erledigt oder verworfen", systemImage: showClosed ? "chevron.down" : "chevron.right")
                            .font(Theme.Fonts.sans(11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)
                    if showClosed { ForEach(closed) { IdeaRow(idea: $0) } }
                }
            }
        }
        .scrollIndicators(.never)
    }
}

private struct IdeaRow: View {
    @Environment(AppStore.self) private var store
    let idea: Idea

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(idea.displayTitle)
                    .font(Theme.Fonts.sans(12.5, .medium))
                    .foregroundStyle(idea.status == .open ? Theme.textPrimary : Theme.textTertiary)
                    .strikethrough(idea.status == .done)
                Spacer(minLength: 0)
                menu
            }
            if let summary = idea.summary {
                Text(summary).font(Theme.Fonts.sans(11.5)).foregroundStyle(Theme.textSecondary)
            } else if idea.title == nil {
                EmptyView()
            } else {
                Text(idea.text).font(Theme.Fonts.sans(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(4)
            }
            HStack(spacing: 6) {
                if let category = idea.category { tag(category) }
                if let effort = idea.effort { tag("Aufwand \(effort)") }
                if idea.duplicateOf != nil { tag("ähnlich wie andere Idee") }
                if idea.source != .mac { tag(idea.source == .siri ? "Siri" : "iPhone") }
                Spacer(minLength: 0)
                analysis
            }
            if let files = idea.relatedFiles, !files.isEmpty {
                Text(files.joined(separator: " · "))
                    .font(Theme.Fonts.mono(10))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            if let note = idea.note {
                Text(note).font(Theme.Fonts.sans(10.5)).foregroundStyle(idea.analysis == .failed ? Theme.orange : Theme.textTertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
    }

    @ViewBuilder private var analysis: some View {
        switch idea.analysis {
        case .pending, .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text(idea.analysis == .running ? "wird eingeordnet" : "wartet auf Engine")
            }
            .font(Theme.Fonts.sans(10))
            .foregroundStyle(Theme.textTertiary)
        case .failed:
            Button("Erneut einordnen") { Task { await store.ideas.analyze(idea.id, projectID: idea.projectID) } }
                .buttonStyle(.plain)
                .font(Theme.Fonts.sans(10, .medium))
                .foregroundStyle(Theme.orange)
        case .done, .off:
            EmptyView()
        }
    }

    private var menu: some View {
        Menu {
            Button("An die Zentrale übergeben", systemImage: "paperplane") {
                store.showHome = true
                Task { await store.dispatcher.send("Setze diese Idee um:\n\n\(idea.summary ?? idea.text)") }
                store.ideas.setStatus(.done, id: idea.id, projectID: idea.projectID)
            }
            Divider()
            ForEach(Idea.Status.allCases, id: \.self) { status in
                Button(status.title) { store.ideas.setStatus(status, id: idea.id, projectID: idea.projectID) }
                    .disabled(idea.status == status)
            }
            Button("Neu einordnen", systemImage: "arrow.clockwise") {
                Task { await store.ideas.analyze(idea.id, projectID: idea.projectID) }
            }
            Divider()
            Button("Löschen", systemImage: "trash", role: .destructive) {
                store.ideas.delete(id: idea.id, projectID: idea.projectID)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(Theme.textTertiary)
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(Theme.Fonts.sans(10))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.lift))
    }
}
