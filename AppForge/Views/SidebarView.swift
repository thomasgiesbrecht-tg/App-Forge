import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @State private var isImporting = false
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Platz für die Ampel-Knöpfe des Fensters
            Color.clear.frame(height: 38)
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())

            Wordmark()
                .padding(.horizontal, 18)
                .padding(.bottom, 22)

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    homeButton
                    projects
                    if store.selectedProject != nil {
                        chats
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)

            Spacer(minLength: 0)
            footer
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await store.addProject(url) } }
        }
    }

    // MARK: Zentrale

    private var homeButton: some View {
        let running = store.dispatcher.runningMissions.count
        return Button {
            withAnimation(Theme.Motion.spring) { store.showHome = true }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 12))
                    .foregroundStyle(running > 0 ? Theme.orange : (store.showHome ? Theme.textPrimary : Theme.textTertiary))
                    .symbolEffect(.variableColor.iterative, isActive: running > 0)
                Text("Zentrale")
                    .font(Theme.Fonts.sans(13, store.showHome ? .medium : .regular))
                    .foregroundStyle(store.showHome ? Theme.textPrimary : Theme.textSecondary)
                Spacer()
                if running > 0 {
                    Text("\(running)")
                        .font(Theme.Fonts.sans(10, .semibold))
                        .foregroundStyle(Theme.void)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.ochre))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background {
                if store.showHome {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.pine.opacity(0.9))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07)))
                        .matchedGeometryEffect(id: "selection", in: selection)
                }
            }
        }
        .buttonStyle(RowButtonStyle())
        .animation(Theme.Motion.bouncy, value: running)
    }

    // MARK: Projekte

    private var projects: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Eyebrow("Projekte")
                Spacer()
                Button { isImporting = true } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Projekt hinzufügen")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(store.projects, id: \.self) { path in
                let isSelected = path == store.selectedProject
                Button {
                    withAnimation(Theme.Motion.spring) { store.showHome = false }
                    Task { await store.openProject(path) }
                } label: {
                    let info = ProjectInfoCache.info(for: path)
                    HStack(spacing: 10) {
                        AppIconView(info: info, size: 30)
                            .opacity(isSelected ? 1 : 0.75)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(info.appName)
                                .font(Theme.Fonts.sans(13, isSelected ? .medium : .regular))
                                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                            Text(info.folderName == info.appName ? path.replacingOccurrences(of: NSHomeDirectory(), with: "~") : "Ordner „\(info.folderName)“")
                                .font(Theme.Fonts.sans(10))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raise)
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line))
                        }
                    }
                }
                .buttonStyle(RowButtonStyle())
                .animation(Theme.Motion.bouncy, value: isSelected)
                .contextMenu {
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                    }
                    Button("Aus Liste entfernen", role: .destructive) { store.removeProject(path) }
                }
            }

            if store.projects.isEmpty {
                Button { isImporting = true } label: {
                    Label("Ordner wählen …", systemImage: "folder.badge.plus")
                        .font(Theme.Fonts.small)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(RowButtonStyle())
            }
        }
    }

    // MARK: Chats

    private var chats: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Eyebrow("Chats")
                Spacer()
                Button {
                    store.showHome = false
                    Task { await store.newSession() }
                } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(IconButtonStyle(size: 22))
                    .help("Neuer Chat (⇧⌘N)")
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            ForEach(store.sessions) { session in
                let isSelected = session.id == store.selectedSessionID
                let activity = store.activity[session.id] ?? .idle
                Button {
                    withAnimation(Theme.Motion.spring) {
                        store.selectedSessionID = session.id
                        store.showHome = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(session.title.isEmpty ? "Neuer Chat" : session.title)
                            .font(Theme.Fonts.sans(12.5, isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if activity != .idle {
                            EmberDot()
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background {
                        if isSelected && !store.showHome {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.pine.opacity(0.9))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.07)))
                                .matchedGeometryEffect(id: "selection", in: selection)
                        }
                    }
                }
                .buttonStyle(RowButtonStyle())
                .animation(Theme.Motion.snappy, value: activity)
                .transition(.riseIn)
                .contextMenu {
                    Button("Löschen", role: .destructive) { Task { await store.deleteSession(session.id) } }
                }
            }
        }
        .animation(Theme.Motion.spring, value: store.sessions.map(\.id))
    }

    // MARK: Fußzeile

    private var footer: some View {
        HStack(spacing: 10) {
            EngineStatusDot(state: store.engineState)
            Text(engineLabel)
                .font(Theme.Fonts.sans(11))
                .foregroundStyle(Theme.textTertiary)
                .contentTransition(.opacity)
            Spacer()
            SettingsLink { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(IconButtonStyle(size: 28))
                .help("Einstellungen (⌘,)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .animation(Theme.Motion.gentle, value: store.engineState)
    }

    private var engineLabel: String {
        switch store.engineState {
        case .running: store.isWorking ? "arbeitet" : "bereit"
        case .starting: "startet"
        case .stopped: "gestoppt"
        case .failed: "Fehler"
        }
    }
}

private struct Wordmark: View {
    var body: some View {
        Text("appforge")
            .font(Theme.Fonts.sans(15, .medium))
            .tracking(-0.3)
            .foregroundStyle(Theme.textPrimary)
    }
}

/// Glimmender Punkt für aktive Chats.
struct EmberDot: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .fill(Theme.ochre)
                .frame(width: 6, height: 6)
                .shadow(color: Theme.orange.opacity(0.6), radius: 2 + 2 * (sin(t * 3) + 1) / 2)
                .opacity(0.6 + 0.4 * (sin(t * 3) + 1) / 2)
        }
        .frame(width: 10, height: 10)
    }
}

private struct EngineStatusDot: View {
    let state: AppStore.EngineState

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)

    }

    private var color: Color {
        switch state {
        case .running: Theme.textSecondary
        case .starting: Theme.orange
        case .stopped: Theme.textTertiary
        case .failed: Theme.orange
        }
    }
}
