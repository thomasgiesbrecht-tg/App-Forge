import SwiftUI

/// Eine App: Chats und Ideen.
struct ProjectView: View {
    @Environment(CompanionModel.self) private var model
    let projectID: String
    @State private var tab: Pane = .chats
    @State private var question = ""
    @State private var answer: String?
    @State private var asking = false

    enum Pane: String, CaseIterable { case chats = "Chats", ideas = "Ideen" }

    private var project: CompanionProject? { model.project(projectID) }

    var body: some View {
        List {
            header
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            Picker("Bereich", selection: $tab) {
                ForEach(Pane.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            switch tab {
            case .chats: chats
            case .ideas: ideas
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Palette.black)
        .navigationTitle(project?.name ?? "App")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { await reload() }
        .onChange(of: model.isConnected) { _, connected in if connected { Task { await reload() } } }
        .sheet(item: Binding(get: { answer.map(Answer.init) }, set: { if $0 == nil { answer = nil } })) { item in
            NavigationStack {
                ScrollView { RichText(text: item.text).padding().frame(maxWidth: .infinity, alignment: .leading) }
                    .navigationTitle("Ideen-Agent")
                    .navigationBarTitleDisplayMode(.inline)
            }
            .presentationDetents([.medium, .large])
        }
    }

    private struct Answer: Identifiable { let text: String; var id: String { text } }

    private func reload() async {
        await model.loadSessions(projectID)
        await model.loadIdeas(projectID)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let project { ProjectIconView(project, size: 56) }
            VStack(alignment: .leading, spacing: 4) {
                Text(project?.name ?? "").font(.title3.weight(.semibold))
                Text(project?.isMac == true ? "Aufgaben auf dem Mac, Konnektoren, MCP" : (project?.folderName ?? ""))
                    .font(.caption).foregroundStyle(Palette.secondary)
                if let spent = project?.spentUSD, spent > 0 {
                    Text("bisher \(spent.euro)").font(.caption).foregroundStyle(Palette.tertiary)
                }
            }
            Spacer()
        }
        .padding(.top, 8)
    }

    // MARK: Chats

    @ViewBuilder private var chats: some View {
        NavigationLink(value: AppsView.Route.chat(projectID: projectID, sessionID: nil)) {
            Label("Neuer Chat", systemImage: "square.and.pencil").foregroundStyle(Palette.accent)
        }
        .listRowBackground(Palette.raise)

        NavigationLink(value: AppsView.Route.chat(projectID: projectID, sessionID: nil, agent: "motion-designer")) {
            Label("Motion Designer: Video oder Animation", systemImage: "film").foregroundStyle(Palette.text)
        }
        .listRowBackground(Palette.raise)

        if project?.isMac != true {
            NavigationLink(value: AppsView.Route.chat(projectID: projectID, sessionID: nil, agent: "kenner")) {
                Label("Frag den Projekt-Kenner", systemImage: "books.vertical").foregroundStyle(Palette.text)
            }
            .listRowBackground(Palette.raise)
        }

        let queued = model.queuedChats(projectID: projectID, sessionID: nil)
        ForEach(queued) { item in
            if case .chat(_, _, _, let text, _) = item {
                HStack {
                    Image(systemName: "clock").foregroundStyle(Palette.secondary)
                    VStack(alignment: .leading) {
                        Text(text).lineLimit(2)
                        Text("wartet auf den Mac").font(.caption).foregroundStyle(Palette.secondary)
                    }
                }
                .listRowBackground(Palette.raise)
                .swipeActions { Button("Löschen", role: .destructive) { model.removeFromOutbox(item) } }
            }
        }

        ForEach(model.sessions[projectID] ?? []) { session in
            NavigationLink(value: AppsView.Route.chat(projectID: projectID, sessionID: session.id)) {
                HStack(spacing: 10) {
                    if session.busy {
                        ProgressView().controlSize(.small).tint(Palette.active)
                    } else {
                        Image(systemName: "bubble.left").foregroundStyle(Palette.tertiary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.title).lineLimit(1)
                        Text(session.updatedAt, style: .relative).font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer()
                    if session.notify { Image(systemName: "bell.fill").font(.caption).foregroundStyle(Palette.secondary) }
                }
            }
            .listRowBackground(Palette.raise)
        }
    }

    // MARK: Ideen

    @ViewBuilder private var ideas: some View {
        HStack(spacing: 12) {
            Button {
                model.capture = .init(projectID: projectID, mode: .write)
            } label: {
                Label("Aufschreiben", systemImage: "square.and.pencil").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
                model.capture = .init(projectID: projectID, mode: .speak)
            } label: {
                Label("Einsprechen", systemImage: "mic.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundStyle(Palette.black)
        }
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)

        HStack {
            TextField("Frag den Ideen-Agenten …", text: $question)
                .submitLabel(.send)
                .onSubmit(ask)
            if asking { ProgressView() } else {
                Button(action: ask) { Image(systemName: "arrow.up.circle.fill").font(.title3) }
                    .disabled(question.isEmpty || !model.isConnected)
            }
        }
        .listRowBackground(Palette.raise)

        let list = model.ideas(for: projectID)
        let open = list.filter { $0.status == .open }
        let closed = list.filter { $0.status != .open }
        if list.isEmpty {
            Text("Noch keine Ideen. Alles, was du hier notierst, sammelt und ordnet der Ideen-Agent auf dem Mac ein – umgesetzt wird nichts.")
                .font(.footnote).foregroundStyle(Palette.secondary)
                .listRowBackground(Color.clear)
        }
        ForEach(open) { IdeaRow(idea: $0) }
        if !closed.isEmpty {
            DisclosureGroup("Erledigt & verworfen (\(closed.count))") {
                ForEach(closed) { IdeaRow(idea: $0) }
            }
            .listRowBackground(Color.clear)
        }
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        asking = true
        Task {
            do {
                answer = try await model.askIdeas(text, projectID: projectID)
                question = ""
            } catch {
                answer = error.localizedDescription
            }
            asking = false
        }
    }
}

struct IdeaRow: View {
    @Environment(CompanionModel.self) private var model
    let idea: Idea

    var body: some View {
        let pending = model.isPending(idea)
        VStack(alignment: .leading, spacing: 6) {
            Text(idea.displayTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(idea.status == .open ? Palette.text : Palette.tertiary)
                .strikethrough(idea.status == .done)
            if let summary = idea.summary {
                Text(summary).font(.footnote).foregroundStyle(Palette.secondary)
            } else if idea.title != nil || pending {
                Text(idea.text).font(.footnote).foregroundStyle(Palette.secondary).lineLimit(4)
            }
            HStack(spacing: 6) {
                if pending {
                    Tag(text: "wartet auf Mac")
                } else {
                    switch idea.analysis {
                    case .pending, .running: Tag(text: "wird eingeordnet …")
                    case .failed: Tag(text: "Einordnung fehlgeschlagen", color: Palette.red)
                    default: EmptyView()
                    }
                }
                if let category = idea.category { Tag(text: category) }
                if let effort = idea.effort { Tag(text: "Aufwand \(effort)") }
                if idea.duplicateOf != nil { Tag(text: "ähnliche Idee vorhanden") }
            }
            if let note = idea.note, idea.analysis != .failed {
                Text(note).font(.caption).foregroundStyle(Palette.tertiary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Palette.raise)
        .swipeActions(edge: .leading) {
            if !pending {
                Button("Erledigt") { Task { await model.setStatus(.done, of: idea) } }.tint(Palette.green)
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Löschen", role: .destructive) { Task { await model.delete(idea) } }
            if !pending {
                Button("Verwerfen") { Task { await model.setStatus(.dismissed, of: idea) } }.tint(Palette.tertiary)
            }
        }
        .contextMenu {
            if !pending {
                Button("Neu einordnen", systemImage: "arrow.clockwise") { Task { await model.analyze(idea) } }
                if idea.status != .open {
                    Button("Wieder öffnen", systemImage: "arrow.uturn.backward") { Task { await model.setStatus(.open, of: idea) } }
                }
                Button("An die Zentrale", systemImage: "sparkles") {
                    Task {
                        await model.sendToZentrale("Setze diese Idee um:\n\n\(idea.summary ?? idea.text)", projectID: idea.projectID)
                        await model.setStatus(.done, of: idea)
                        model.selectedTab = .zentrale
                    }
                }
            }
            if let files = idea.relatedFiles, !files.isEmpty {
                Section("Betroffene Dateien") { ForEach(files, id: \.self) { Text($0) } }
            }
        }
    }
}
