import SwiftUI

/// AppForge auf der Apple Watch: Überblick, Freigaben, Aufträge und Ideen – alles über das iPhone.
@main
struct AppForgeWatchApp: App {
    @State private var model: WatchModel

    init() {
        let model = WatchModel()
        model.activate()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(model)
                .tint(WatchPalette.green)
        }
    }
}

/// Farben wie in AppForge: Grün = läuft gut/fertig, Orange = du musst etwas tun, Rot = Problem.
enum WatchPalette {
    static let green = Color(red: 0.298, green: 0.851, blue: 0.482)
    static let orange = Color(red: 1.0, green: 0.541, blue: 0.2)
    static let red = Color(red: 0.949, green: 0.333, blue: 0.353)
    static let secondary = Color(white: 0.62)
    static let tertiary = Color(white: 0.42)
}

struct WatchRootView: View {
    @Environment(WatchModel.self) private var model
    @State private var page = 0
    @State private var showIdea = false

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                OverviewPage(showPermissions: { withAnimation { page = 1 } }, showIdea: { showIdea = true })
                    .tag(0)
                PermissionsPage()
                    .tag(1)
                MissionsPage()
                    .tag(2)
            }
            .tabViewStyle(.verticalPage)
            .sheet(isPresented: $showIdea) { IdeaSheet() }
            .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK") { model.message = nil }
            }
        }
        .onAppear { model.refresh() }
    }
}

// MARK: Übersicht

private struct OverviewPage: View {
    @Environment(WatchModel.self) private var model
    let showPermissions: () -> Void
    let showIdea: () -> Void

    var body: some View {
        let state = model.state
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(state.connected ? WatchPalette.green : WatchPalette.tertiary)
                        .frame(width: 7, height: 7)
                    Text(state.connected ? state.macName : (model.iPhoneReachable ? "Mac nicht verbunden" : "iPhone nicht erreichbar"))
                        .font(.footnote)
                        .foregroundStyle(WatchPalette.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text("\(state.running)")
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(state.running > 0 ? WatchPalette.green : .primary)
                        .contentTransition(.numericText())
                    Text(state.running == 1 ? "Auftrag läuft" : "Aufträge laufen")
                        .font(.footnote)
                        .foregroundStyle(WatchPalette.secondary)
                }

                if !state.permissions.isEmpty {
                    Button(action: showPermissions) {
                        Label(state.permissions.count == 1 ? "1 Freigabe offen" : "\(state.permissions.count) Freigaben offen",
                              systemImage: "hand.raised.fill")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(WatchPalette.orange)
                    }
                    .buttonStyle(.bordered)
                    .tint(WatchPalette.orange)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text("heute").font(.caption2).foregroundStyle(WatchPalette.tertiary)
                    Text(state.euro(state.spentTodayUSD)).font(.caption.monospacedDigit())
                }

                Button(action: showIdea) {
                    Label("Idee notieren", systemImage: "mic")
                }
                .buttonStyle(.borderedProminent)

                if state.updatedAt > .distantPast {
                    Text("Stand \(state.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption2)
                        .foregroundStyle(WatchPalette.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("AppForge")
    }
}

// MARK: Freigaben

private struct PermissionsPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let permissions = model.state.permissions
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if permissions.isEmpty {
                    Label("Keine Freigaben offen", systemImage: "checkmark")
                        .font(.footnote)
                        .foregroundStyle(WatchPalette.secondary)
                        .padding(.top, 8)
                }
                ForEach(permissions) { permission in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(permission.title).font(.footnote.weight(.semibold)).lineLimit(2)
                        Text(title(of: permission.kind)).font(.caption2).foregroundStyle(WatchPalette.orange)
                        if let detail = permission.detail {
                            Text(detail)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(WatchPalette.secondary)
                                .lineLimit(5)
                        }
                        HStack(spacing: 6) {
                            Button("Nein") { model.reply(permission, allow: false) }
                                .tint(WatchPalette.red)
                            Button("Erlauben") { model.reply(permission, allow: true) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .navigationTitle("Freigaben")
    }

    private func title(of kind: String) -> String {
        switch kind {
        case "bash": "Befehl ausführen"
        case "edit", "write": "Datei ändern"
        case "external_directory": "Zugriff außerhalb des Projekts"
        default: kind
        }
    }
}

// MARK: Aufträge

private struct MissionsPage: View {
    @Environment(WatchModel.self) private var model

    var body: some View {
        let state = model.state
        let missions = state.missions.filter { !$0.isFinished } + state.missions.filter(\.isFinished).prefix(6)
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if missions.isEmpty {
                    Text("Noch keine Aufträge.").font(.footnote).foregroundStyle(WatchPalette.secondary).padding(.top, 8)
                }
                ForEach(missions) { mission in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Circle().fill(color(mission)).frame(width: 6, height: 6)
                            Text(mission.title).font(.footnote.weight(.semibold)).lineLimit(1)
                        }
                        Text(mission.projectName).font(.caption2).foregroundStyle(WatchPalette.tertiary)
                        if let activity = mission.activity, !mission.isFinished {
                            Text(activity).font(.caption2).foregroundStyle(WatchPalette.secondary).lineLimit(2)
                        }
                        if let progress = mission.progress, !mission.isFinished {
                            ProgressView(value: progress).tint(WatchPalette.green)
                        }
                        Text("\(mission.stateTitle) · \(state.euro(mission.spentUSD))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(mission.buildOK == false ? WatchPalette.red : WatchPalette.tertiary)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .navigationTitle("Aufträge")
    }

    private func color(_ mission: WatchState.Mission) -> Color {
        if !mission.isFinished { return WatchPalette.green }
        return mission.buildOK == false || mission.stateTitle == "fehlgeschlagen" ? WatchPalette.red : WatchPalette.tertiary
    }
}

// MARK: Idee

private struct IdeaSheet: View {
    @Environment(WatchModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var projectID: String?
    @State private var text = ""

    var body: some View {
        let projects = model.state.projects
        NavigationStack {
            List {
                Section("Für welche App?") {
                    if projects.isEmpty {
                        Text("Noch keine Apps – öffne AppForge einmal auf dem iPhone.").font(.footnote)
                    }
                    ForEach(projects) { project in
                        Button {
                            projectID = project.id
                        } label: {
                            HStack {
                                Text(project.name).lineLimit(1)
                                Spacer()
                                if projectID == project.id { Image(systemName: "checkmark").foregroundStyle(WatchPalette.green) }
                            }
                        }
                    }
                }
                if projectID != nil {
                    Section("Idee") {
                        // Tippen öffnet die Eingabe – dort lässt sich die Idee einsprechen.
                        TextField("Sprechen oder schreiben", text: $text)
                        Button("Senden") {
                            if let projectID { model.addIdea(text, projectID: projectID) }
                            dismiss()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            .navigationTitle("Idee")
        }
        .onAppear { if projects.count == 1 { projectID = projects[0].id } }
    }
}
