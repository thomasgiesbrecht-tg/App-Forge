import SwiftUI

/// Alle Apps vom Mac (plus der Bereich „Mac“) – Ausgangspunkt für Chats und Ideen.
struct AppsView: View {
    @Environment(CompanionModel.self) private var model
    @State private var path: [Route] = []
    @State private var addingProject = false

    enum Route: Hashable {
        case project(String)
        case chat(projectID: String, sessionID: String?)
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if model.projects.isEmpty {
                    ContentUnavailableView(
                        "Noch keine Apps",
                        systemImage: "square.grid.2x2",
                        description: Text(model.pairing == nil ? "Koppel zuerst deinen Mac unter „Mac“." : "Sobald der Mac erreichbar ist, erscheinen hier deine Projekte.")
                    )
                    .padding(.top, 60)
                }
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(model.projects) { project in
                        NavigationLink(value: Route.project(project.id)) {
                            VStack(spacing: 8) {
                                ProjectIconView(project, size: 64)
                                    .overlay(alignment: .topTrailing) {
                                        if project.openIdeas > 0 {
                                            Text("\(project.openIdeas)")
                                                .font(.caption2.weight(.bold))
                                                .foregroundStyle(Palette.black)
                                                .padding(.horizontal, 5)
                                                .frame(minWidth: 18, minHeight: 18)
                                                .background(Capsule().fill(Palette.orange))
                                                .offset(x: 6, y: -6)
                                        }
                                    }
                                Text(project.name).font(.footnote).foregroundStyle(Palette.text).lineLimit(1)
                            }
                        }
                        .contextMenu {
                            Button("Idee notieren", systemImage: "lightbulb") { model.capture = .init(projectID: project.id, mode: .write) }
                            Button("Idee einsprechen", systemImage: "mic") { model.capture = .init(projectID: project.id, mode: .speak) }
                            Button("Neuer Chat", systemImage: "bubble.left.and.text.bubble.right") { path.append(.chat(projectID: project.id, sessionID: nil)) }
                        }
                    }
                }
                .padding()
            }
            .background(Palette.black)
            .navigationTitle("Apps")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { addingProject = true } label: { Image(systemName: "plus") }
                        .disabled(!model.isConnected)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .project(let id): ProjectView(projectID: id)
                case .chat(let projectID, let sessionID): ChatScreen(projectID: projectID, sessionID: sessionID)
                }
            }
            .sheet(isPresented: $addingProject) { AddProjectView() }
            .onChange(of: model.pendingChat?.sessionID, initial: true) { _, _ in
                guard let target = model.pendingChat else { return }
                model.pendingChat = nil
                path = [.project(target.projectID), .chat(projectID: target.projectID, sessionID: target.sessionID)]
            }
        }
    }
}

/// Xcode-Projekte auf dem Mac finden und zu AppForge hinzufügen.
struct AddProjectView: View {
    @Environment(CompanionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var found: [DiscoveredProject] = []
    @State private var loading = true
    @State private var error: String?
    @State private var adding: String?

    var body: some View {
        NavigationStack {
            List {
                if loading { HStack { ProgressView(); Text("Suche auf dem Mac …").foregroundStyle(Palette.secondary) } }
                if let error { Text(error).foregroundStyle(Palette.orange) }
                if !loading && found.isEmpty && error == nil {
                    Text("Keine weiteren Xcode-Projekte gefunden (gesucht in Developer, Projekte, Dokumente, Schreibtisch …).")
                        .foregroundStyle(Palette.secondary)
                }
                ForEach(found) { project in
                    Button {
                        adding = project.id
                        Task {
                            do {
                                try await model.addProject(project.id)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                            adding = nil
                        }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(project.name).foregroundStyle(Palette.text)
                                Text(project.detail).font(.caption).foregroundStyle(Palette.secondary)
                            }
                            Spacer()
                            if adding == project.id { ProgressView() } else { Image(systemName: "plus.circle.fill") }
                        }
                    }
                    .disabled(adding != nil)
                }
            }
            .navigationTitle("Projekt hinzufügen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
            .task {
                do { found = try await model.discoverProjects() } catch { self.error = error.localizedDescription }
                loading = false
            }
        }
    }
}
