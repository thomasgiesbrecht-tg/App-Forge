import SwiftUI

struct ContentView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            AmbientBackground(isWorking: store.isWorking)

            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: 236)
                        .background(Theme.black)
                        .overlay(alignment: .trailing) { Rectangle().fill(Theme.line).frame(width: 1) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }

                Group {
                    switch store.engineState {
                    case .running:
                        if store.showHome {
                            ZentraleView()
                        } else if store.selectedProject == nil {
                            NoProjectView()
                        } else {
                            ChatView()
                        }
                    default:
                        EngineStatusView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            .animation(Theme.Motion.spring, value: store.engineState)
            .animation(Theme.Motion.spring, value: store.showHome)
        }
        .foregroundStyle(Theme.textPrimary)
        .ignoresSafeArea()
        .alert("Fehler", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
    }
}

// MARK: Leere Zustände

private struct NoProjectView: View {
    @Environment(AppStore.self) private var store
    @State private var isImporting = false
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 22) {
            EmberMark(size: 88, intensity: 0.6)
            VStack(spacing: 8) {
                Text("Öffne ein Projekt")
                    .font(Theme.Fonts.display)
                Text("Wähle den Ordner deiner iOS-, iPadOS- oder macOS-App.")
                    .font(Theme.Fonts.body)
                    .foregroundStyle(Theme.textSecondary)
            }
            Button {
                isImporting = true
            } label: {
                Label("Ordner wählen", systemImage: "folder")
            }
            .buttonStyle(PillButtonStyle(prominent: true))
        }
        .modifier(RiseIn(active: !appeared))
        .onAppear { withAnimation(Theme.Motion.spring.delay(0.1)) { appeared = true } }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { Task { await store.addProject(url) } }
        }
    }
}

struct EngineStatusView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 24) {
            switch store.engineState {
            case .failed(let message):
                Image(systemName: "flame")
                    .font(.system(size: 34, weight: .ultraLight))
                    .foregroundStyle(Theme.clay)
                    .symbolEffect(.pulse)
                VStack(spacing: 10) {
                    Text("Die Engine ist nicht gestartet")
                        .font(Theme.Fonts.sans(22, .light))
                    Text(message)
                        .font(Theme.Fonts.small)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: 460)
                }
                HStack(spacing: 10) {
                    Button("Erneut versuchen") { Task { await store.restartEngine() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                    SettingsLink { Text("Einstellungen") }
                        .buttonStyle(PillButtonStyle())
                }
            default:
                EmberMark(size: 96)
                ShimmerText(text: "Die Esse wird angeheizt …", font: Theme.Fonts.sans(13, .light))
            }
        }
        .padding(40)
    }
}
