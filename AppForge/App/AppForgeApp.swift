import SwiftUI

@main
struct AppForgeApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup("AppForge") {
            ContentView()
                .environment(store)
                .frame(minWidth: 920, minHeight: 620)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .font(Theme.Fonts.body)
                .task { await store.startEngine() }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1220, height: 800)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Neuer Chat") { Task { await store.newSession() } }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(store.selectedProject == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("Seitenleiste ein-/ausblenden") {
                    withAnimation(Theme.Motion.spring) { store.sidebarVisible.toggle() }
                }
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
            CommandMenu("Engine") {
                Button("Engine neu starten") { Task { await store.restartEngine() } }
                    .keyboardShortcut("r", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
                .font(Theme.Fonts.body)
        }
    }
}
