import SwiftUI

/// Laufende und fertige Aufträge, offene Freigaben und der Ereignisticker.
struct MissionsView: View {
    @Environment(CompanionModel.self) private var model

    private var missions: [CompanionMission] { model.snapshot?.missions ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if !model.permissions.isEmpty {
                    Section("Braucht deine Freigabe") {
                        ForEach(model.permissions) { PermissionCard(permission: $0) }
                    }
                }
                let running = missions.filter { !$0.isFinished }
                if !running.isEmpty {
                    Section("Läuft") { ForEach(running) { MissionRow(mission: $0) } }
                }
                let finished = missions.filter(\.isFinished)
                if !finished.isEmpty {
                    Section("Fertig") { ForEach(finished.prefix(15)) { MissionRow(mission: $0) } }
                }
                if let events = model.snapshot?.events, !events.isEmpty {
                    Section("Ereignisse") {
                        ForEach(events.prefix(12)) { event in
                            HStack(alignment: .firstTextBaseline) {
                                Circle().fill(color(event.tone)).frame(width: 6, height: 6)
                                VStack(alignment: .leading) {
                                    Text(event.source).font(.caption.weight(.semibold))
                                    Text(event.text).font(.caption).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                Text(event.date, style: .time).font(.caption2).foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                }
                if missions.isEmpty && model.permissions.isEmpty {
                    ContentUnavailableView("Keine Aufträge", systemImage: "hammer",
                                           description: Text("Aufträge startest du über die Zentrale."))
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.black)
            .navigationTitle("Aufträge")
            .toolbar {
                if let snapshot = model.snapshot {
                    ToolbarItem(placement: .topBarTrailing) {
                        Text("heute \(snapshot.spentToday.euro)").font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
    }

    private func color(_ tone: CompanionEvent.Tone) -> Color {
        switch tone {
        case .neutral: Palette.tertiary
        case .good: Palette.green
        case .attention: Palette.orange
        case .problem: Palette.red
        }
    }
}

private struct PermissionCard: View {
    @Environment(CompanionModel.self) private var model
    let permission: CompanionPermission
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(permission.title).font(.subheadline.weight(.semibold))
            Text(kind).font(.caption).foregroundStyle(Palette.orange)
            if !permission.patterns.isEmpty {
                Text(permission.patterns.joined(separator: "\n"))
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(expanded ? nil : 3)
            }
            if let detail = permission.detail {
                Text(detail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(expanded ? nil : 6)
                    .onTapGesture { withAnimation { expanded.toggle() } }
            }
            HStack {
                Button("Einmal") { Task { await model.reply(permission, .once) } }
                    .buttonStyle(.borderedProminent).foregroundStyle(Palette.black)
                Button("Immer") { Task { await model.reply(permission, .always) } }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Ablehnen", role: .destructive) { Task { await model.reply(permission, .reject) } }
                    .buttonStyle(.bordered)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
    }

    private var kind: String {
        switch permission.permission {
        case "bash": "möchte einen Befehl ausführen"
        case "edit", "write": "möchte Dateien ändern"
        case "external_directory": "möchte außerhalb des Projekts arbeiten"
        default: "möchte: \(permission.permission)"
        }
    }
}

private struct MissionRow: View {
    @Environment(CompanionModel.self) private var model
    let mission: CompanionMission

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(mission.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer()
                Tag(text: mission.stateTitle, color: mission.isFinished ? (mission.state == "done" ? Palette.green : Palette.red) : Palette.active)
            }
            Text("\(mission.projectName) · \(mission.agent) · \(mission.model)")
                .font(.caption).foregroundStyle(Palette.tertiary).lineLimit(1)
            if let activity = mission.activity {
                Text(activity).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(3)
            }
            if let progress = mission.progress, !mission.isFinished {
                ProgressView(value: progress).tint(Palette.accent)
            }
            HStack(spacing: 6) {
                Tag(text: mission.spentUSD.euro + (mission.budgetUSD.map { " / \($0.euro)" } ?? ""))
                if !mission.files.isEmpty { Tag(text: "\(mission.files.count) Dateien +\(mission.additions) −\(mission.deletions)") }
                if let ok = mission.buildOK { Tag(text: ok ? "Build ✓" : "Build ✗\(mission.buildErrors.map { " \($0)" } ?? "")", color: ok ? Palette.green : Palette.red) }
                if let tests = mission.testsLabel { Tag(text: tests, color: mission.testsOK == false ? Palette.red : Palette.green) }
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            if !mission.isFinished {
                Button("Stoppen", role: .destructive) { Task { await model.stop(mission) } }
            }
        }
    }
}
