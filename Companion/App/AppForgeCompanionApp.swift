import SwiftUI

@main
struct AppForgeCompanionApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = CompanionModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
                .onOpenURL { model.handle($0) }
                .onAppear { AppDelegate.model = model }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active: model.becameActive()
                    case .background: model.becameInactive()
                    default: break
                    }
                }
        }
    }
}
