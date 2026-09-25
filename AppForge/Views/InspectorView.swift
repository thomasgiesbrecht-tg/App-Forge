import SwiftUI

/// Rechte Seitenleiste: Live-Simulator und Änderungen des Chats.
struct InspectorView: View {
    @Environment(AppStore.self) private var store
    @Namespace private var tabIndicator

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                tab(.simulator, "Simulator", "iphone.gen3")
                tab(.changes, "Änderungen", "plusminus")
                tab(.ideas, "Ideen", "lightbulb")
                tab(.knowledge, "Wissen", "books.vertical")
            }
            .padding(3)
            .glass(cornerRadius: 14, tintOpacity: 0.3, shadow: false)
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Group {
                switch store.inspectorTab {
                case .simulator: SimulatorPanel()
                case .changes: ChangesPanel()
                case .ideas: IdeasPanel()
                case .knowledge: KnowledgePanel()
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98)))
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .animation(Theme.Motion.spring, value: store.inspectorTab)
    }

    private func tab(_ tab: AppStore.InspectorTab, _ title: String, _ symbol: String) -> some View {
        let selected = store.inspectorTab == tab
        return Button {
            withAnimation(Theme.Motion.bouncy) { store.inspectorTab = tab }
        } label: {
            Label(title, systemImage: symbol)
                .font(Theme.Fonts.sans(11.5, selected ? .medium : .regular))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if selected {
                        Capsule().fill(Theme.pine)
                            .overlay(Capsule().strokeBorder(Theme.line))
                            .matchedGeometryEffect(id: "tab", in: tabIndicator)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Simulator

private struct SimulatorPanel: View {
    @Environment(AppStore.self) private var store
    @State private var dark = true
    @State private var sending = false

    private var simulator: SimulatorService { store.simulator }

    var body: some View {
        VStack(spacing: 14) {
            if store.platform == .macOS {
                ContentUnavailableView {
                    Label("Mac-App", systemImage: "macbook")
                } description: {
                    Text("Mac-Apps laufen direkt auf deinem Mac – dafür braucht es keinen Simulator. Stelle oben auf iPhone oder iPad um.")
                }
                .foregroundStyle(Theme.textSecondary)
            } else {
                devicePicker
                screen
                controls
                if let error = simulator.lastError {
                    Text(error).font(Theme.Fonts.sans(11)).foregroundStyle(Theme.clay)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .task(id: store.platform) { await simulator.refreshDevices(for: store.platform) }
    }

    private var devicePicker: some View {
        Menu {
            ForEach(simulator.devices) { device in
                Button {
                    simulator.selectedUDID = device.udid
                } label: {
                    Label("\(device.name) · \(device.runtime)", systemImage: device.isBooted ? "circle.fill" : (device.isPad ? "ipad" : "iphone"))
                }
            }
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(simulator.selectedDevice?.isBooted == true ? Theme.sage : Theme.smoke)
                    .frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 0) {
                    Text(simulator.selectedDevice?.name ?? "Gerät wählen")
                        .font(Theme.Fonts.sans(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text(simulator.selectedDevice.map { "\($0.runtime) · \($0.isBooted ? "läuft" : "aus")" } ?? "")
                        .font(Theme.Fonts.sans(10))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glass(cornerRadius: 12, tintOpacity: 0.3, shadow: false)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    private var screen: some View {
        let booted = simulator.selectedDevice?.isBooted == true
        return ZStack {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Theme.void)
                .overlay(RoundedRectangle(cornerRadius: 34, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1.5))

            if booted, let frame = simulator.frame {
                Image(nsImage: frame)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .padding(6)
                    .transition(.opacity)
            } else if booted {
                ForgeSpinner(size: 22)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "power")
                        .font(.system(size: 26, weight: .ultraLight))
                        .foregroundStyle(Theme.textTertiary)
                    Button(simulator.isBusy ? "Startet …" : "Simulator starten") { Task { await simulator.boot() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(simulator.isBusy || simulator.selectedDevice == nil)
                }
            }
        }
        .aspectRatio(simulator.selectedDevice?.isPad == true ? 0.75 : 0.47, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .animation(Theme.Motion.gentle, value: booted)
        .task(id: "\(simulator.selectedUDID ?? "")-\(booted)") {
            // Live-Bild: etwa zwei Bilder pro Sekunde, solange das Panel sichtbar ist.
            guard booted else { return }
            while !Task.isCancelled {
                await simulator.captureFrame()
                try? await Task.sleep(for: .milliseconds(450))
            }
        }
    }

    private var controls: some View {
        let booted = simulator.selectedDevice?.isBooted == true
        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    sending = true
                    Task {
                        if let shot = await simulator.screenshotAttachment() {
                            withAnimation(Theme.Motion.bouncy) { store.addAttachments([shot]) }
                        }
                        sending = false
                    }
                } label: {
                    Label(sending ? "…" : "In den Chat", systemImage: "camera.viewfinder")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(!booted || sending)
                .help("Screenshot als Anhang ins Eingabefeld legen")

                Button {
                    dark.toggle()
                    Task { await simulator.setAppearance(dark: dark) }
                } label: {
                    Image(systemName: dark ? "moon.fill" : "sun.max.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(IconButtonStyle(size: 30))
                .disabled(!booted)
                .help("Hell/Dunkel umschalten")

                Button { simulator.openSimulatorApp() } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .help("Im Simulator öffnen (zum Bedienen)")

                Button { Task { await simulator.shutdown() } } label: { Image(systemName: "power") }
                    .buttonStyle(IconButtonStyle(size: 30, tint: Theme.clay))
                    .disabled(!booted)
                    .help("Simulator ausschalten")
            }
            Text("Die KI steuert den Simulator über XcodeBuildMCP. Zum selbst Tippen: „Im Simulator öffnen“.")
                .font(Theme.Fonts.sans(10))
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}

// MARK: Änderungen

private struct ChangesPanel: View {
    @Environment(AppStore.self) private var store
    @State private var expanded: Set<String> = []

    var body: some View {
        let changes = store.currentChanges
        VStack(alignment: .leading, spacing: 10) {
            if changes.isEmpty {
                ContentUnavailableView {
                    Label("Keine Änderungen", systemImage: "doc.on.doc")
                } description: {
                    Text("Sobald die KI Dateien ändert, erscheinen sie hier – mit allen Zeilen.")
                }
                .foregroundStyle(Theme.textSecondary)
            } else {
                HStack {
                    Eyebrow("\(changes.count) \(changes.count == 1 ? "Datei" : "Dateien")")
                    Spacer()
                    ChangeCounts(additions: changes.reduce(0) { $0 + $1.additions }, deletions: changes.reduce(0) { $0 + $1.deletions })
                }
                .padding(.horizontal, 4)

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(changes) { change in
                            FileChangeRow(change: change, expanded: expanded.contains(change.id)) {
                                withAnimation(Theme.Motion.spring) {
                                    if expanded.contains(change.id) { expanded.remove(change.id) } else { expanded.insert(change.id) }
                                }
                            }
                        }
                    }
                }
                .scrollIndicators(.never)

                Text("Rückgängig machen: In der Nachricht auf „Ab hier zurücksetzen“ gehen.")
                    .font(Theme.Fonts.sans(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }
}

private struct FileChangeRow: View {
    let change: FileChange
    let expanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11))
                        .foregroundStyle(color)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(change.name)
                            .font(Theme.Fonts.sans(12, .medium))
                            .foregroundStyle(Theme.textPrimary)
                        if let file = change.file, file.contains("/") {
                            Text((file as NSString).deletingLastPathComponent)
                                .font(Theme.Fonts.sans(9.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                    Spacer()
                    ChangeCounts(additions: change.additions, deletions: change.deletions)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded, let patch = change.patch, !patch.isEmpty {
                DiffText(patch: patch)
                    .frame(maxHeight: 360)
                    .padding([.horizontal, .bottom], 8)
                    .transition(.asymmetric(insertion: .riseIn, removal: .opacity))
            }
        }
        .glass(cornerRadius: 12, tintOpacity: 0.25, shadow: false)
    }

    private var icon: String {
        switch change.status {
        case "added": "plus.circle"
        case "deleted": "minus.circle"
        default: "pencil.circle"
        }
    }

    private var color: Color {
        switch change.status {
        case "added": Theme.sage
        case "deleted": Theme.clay
        default: Theme.ochre
        }
    }
}
