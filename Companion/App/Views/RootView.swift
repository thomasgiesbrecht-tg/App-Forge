import SwiftUI

struct RootView: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Apps", systemImage: "square.grid.2x2.fill", value: .apps) { AppsView() }
            Tab("Zentrale", systemImage: "sparkles", value: .zentrale) { ZentraleView() }
            Tab("Aufträge", systemImage: "hammer.fill", value: .missions) { MissionsView() }
                .badge(model.permissions.count)
            Tab("Mac", systemImage: "desktopcomputer", value: .mac) { MacView() }
        }
        .safeAreaInset(edge: .top, spacing: 0) { ConnectionBanner() }
        .background(Palette.black.ignoresSafeArea())
        .sheet(item: $model.capture) { request in
            IdeaCaptureView(projectID: request.projectID, mode: request.mode)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .alert("Hinweis", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.clearError() } })) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}
