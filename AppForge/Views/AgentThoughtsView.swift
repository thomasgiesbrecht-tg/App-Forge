import SwiftUI

/// Links in der Live-Ansicht: die Gedanken eines angeklickten Agenten – was er überlegt,
/// welche Schritte er macht und was er antwortet. Läuft live mit.
struct AgentThoughtsView: View {
    @Environment(AppStore.self) private var store
    let focus: ThoughtFocus

    private var dispatcher: Dispatcher { store.dispatcher }
    private var mission: Mission? { focus.missionID.flatMap { id in dispatcher.missions.first { $0.id == id } } }
    private var isDemo: Bool { focus.sessionID == nil && focus.missionID == nil }

    private var items: [ThoughtItem] {
        if isDemo { return ThoughtStream.demo(for: focus.nodeID) }
        guard let sessionID = focus.sessionID else { return [] }
        return ThoughtStream.items(from: store.messages[sessionID] ?? [])
    }

    private var isWorking: Bool {
        if isDemo { return true }
        if let sessionID = focus.sessionID, store.activity[sessionID] == .busy { return true }
        return mission.map { $0.state == .running || $0.state == .wrappingUp } ?? false
    }

    var body: some View {
        let items = items
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        if items.isEmpty {
                            emptyState
                        } else if !items.contains(where: { $0.kind == .thought }) {
                            Text("Dieses Modell legt seine Gedanken nicht offen. Du siehst seine Schritte und Antworten.")
                                .font(Theme.Fonts.sans(11))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(items) { item in
                            ThoughtRow(item: item, onOpenChild: openChild)
                                .id(item.id)
                        }
                        if isWorking && !items.isEmpty {
                            BreathingDots(color: Theme.textSecondary)
                                .padding(.leading, 2)
                                .padding(.top, 2)
                        }
                        Color.clear.frame(height: 1).id("ende")
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .onAppear { proxy.scrollTo("ende", anchor: .bottom) }
                .onChange(of: items.count) { withAnimation(Theme.Motion.snappy) { proxy.scrollTo("ende", anchor: .bottom) } }
            }
        }
        .task(id: focus.sessionID) {
            guard let sessionID = focus.sessionID, let directory = focus.directory ?? store.selectedProject else { return }
            await store.reloadSession(sessionID, directory: directory)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(Theme.Motion.spring) { dispatcher.focus = nil }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle(size: 26))
            .help("Zurück zum Gespräch mit der Zentrale")

            ZStack {
                Circle().fill(Theme.lift)
                Image(systemName: focus.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(isWorking ? Theme.active : Theme.textSecondary)
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(focus.title)
                    .font(Theme.Fonts.sans(13, .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text("Gedanken · " + focus.subtitle)
                    .font(Theme.Fonts.sans(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let mission, !mission.sessionID.isEmpty {
                Button("Chat öffnen") { Task { await store.open(mission) } }
                    .buttonStyle(PillButtonStyle())
                    .help("Den vollständigen Chat dieses Auftrags öffnen – dort kannst du auch eingreifen.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(mission?.state == .waiting ? "Dieser Agent hat noch nicht angefangen." : "Noch keine Gedanken.")
                .font(Theme.Fonts.sans(13))
                .foregroundStyle(Theme.textSecondary)
            if let activity = mission?.activity {
                Text(activity)
                    .font(Theme.Fonts.sans(12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.top, 8)
    }

    /// Unteragent aus einem Schritt heraus öffnen.
    private func openChild(_ childSessionID: String, _ title: String) {
        let prefix = focus.missionID?.uuidString ?? focus.nodeID
        withAnimation(Theme.Motion.spring) {
            dispatcher.focus = ThoughtFocus(
                nodeID: "\(prefix)-\(childSessionID)", sessionID: childSessionID, directory: focus.directory,
                missionID: focus.missionID, title: title, subtitle: "Unteragent von \(focus.title)", symbol: "person.crop.circle"
            )
        }
    }
}

/// Ein Eintrag im Gedankenstrom.
private struct ThoughtRow: View {
    let item: ThoughtItem
    let onOpenChild: (String, String) -> Void
    @State private var expanded = false

    var body: some View {
        switch item.kind {
        case .instruction:
            VStack(alignment: .leading, spacing: 5) {
                Eyebrow("Auftrag")
                Text(item.text)
                    .font(Theme.Fonts.sans(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(expanded ? nil : 5)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture { withAnimation(Theme.Motion.snappy) { expanded.toggle() } }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.raise, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))

        case .thought:
            HStack(alignment: .top, spacing: 10) {
                Rectangle()
                    .fill(Theme.textTertiary.opacity(0.5))
                    .frame(width: 1)
                Text(item.text)
                    .font(Theme.Fonts.sans(12.5).italic())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .step(let status, let child):
            HStack(spacing: 8) {
                Group {
                    switch status {
                    case "running", "pending": ForgeSpinner(size: 10, lineWidth: 1.4)
                    case "error": Image(systemName: "xmark").foregroundStyle(Theme.red)
                    default: Image(systemName: "checkmark").foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 12)
                Text(item.text)
                    .font(Theme.Fonts.mono(11))
                    .foregroundStyle(status == "error" ? Theme.red : Theme.textTertiary)
                    .lineLimit(1)
                if let child {
                    Button("Gedanken ansehen") { onOpenChild(child, item.text.replacingOccurrences(of: "beauftragt ", with: "")) }
                        .buttonStyle(.plain)
                        .font(Theme.Fonts.sans(10.5, .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

        case .answer:
            MarkdownText(text: item.text)
                .font(Theme.Fonts.sans(13))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }
}
