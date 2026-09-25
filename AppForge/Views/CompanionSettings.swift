import SwiftUI
import UniformTypeIdentifiers

/// Einstellungen → iPhone: Kopplung, Erreichbarkeit, Push-Schlüssel.
struct CompanionSettings: View {
    @Environment(AppStore.self) private var store
    @State private var importingKey = false
    @State private var keyError: String?
    @State private var teamID = CompanionPairing.teamIdentifier ?? ""
    @State private var detecting = false
    @State private var copied = false
    @State private var confirmReset = false

    private var bridge: CompanionBridge { store.companion }

    var body: some View {
        @Bindable var bridge = bridge
        Form {
            Section {
                Toggle("iPhone-Verbindung aktiv", isOn: $bridge.enabled)
                LabeledContent("Status") { statusText }
                if !bridge.clients.isEmpty {
                    LabeledContent("Verbunden") {
                        Text(bridge.clients.map(\.deviceName).joined(separator: ", "))
                    }
                }
            } footer: {
                Text("Ideen, Chats, Zentrale, Aufträge und Freigaben sind damit auch auf dem iPhone verfügbar. Die Verbindung ist mit dem Schlüssel aus dem QR-Code verschlüsselt.")
            }

            Section("Koppeln") {
                HStack(alignment: .top, spacing: 16) {
                    if let image = CompanionPairing.qrCode(for: bridge.pairingInfo.url) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 160, height: 160)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scanne den Code mit der **Kamera-App** des iPhones – die AppForge-Companion-App öffnet sich und koppelt sich automatisch.")
                        Text("Oder kopiere den Link und füge ihn in der iPhone-App unter „Mac“ ein (geht per geteilter Zwischenablage).")
                            .foregroundStyle(.secondary)
                        Button(copied ? "Kopiert" : "Kopplungs-Link kopieren") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bridge.pairingInfo.url.absoluteString, forType: .string)
                            copied = true
                        }
                        Button("Kopplung zurücksetzen …", role: .destructive) { confirmReset = true }
                            .confirmationDialog("Alle iPhones müssen danach neu koppeln.", isPresented: $confirmReset) {
                                Button("Zurücksetzen", role: .destructive) { bridge.resetPairing() }
                            }
                    }
                }
                if !bridge.devices.isEmpty {
                    ForEach(bridge.devices) { device in
                        LabeledContent(device.name) {
                            Text(device.pushToken == nil ? "ohne Push" : "Push bereit")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                HStack {
                    TextField("Adresse für unterwegs", text: $bridge.remoteHost, prompt: Text("z. B. mein-mac.tailnet.ts.net"))
                    Button(detecting ? "Suche …" : "Tailscale erkennen") {
                        detecting = true
                        Task {
                            if let host = await CompanionPairing.detectTailscaleHost() { bridge.remoteHost = host }
                            detecting = false
                        }
                    }
                    .disabled(detecting)
                }
                Toggle("Mac wach halten", isOn: $bridge.keepAwake)
            } header: {
                Text("Unterwegs erreichbar")
            } footer: {
                Text("Mit Tailscale auf Mac und iPhone erreicht die App den Mac auch unterwegs. Nach einer Änderung der Adresse einmal neu koppeln. Ein zugeklapptes MacBook schläft ohne externen Monitor trotzdem ein – am besten aufgeklappt am Strom lassen.")
            }

            Section {
                if let credentials = bridge.push.credentials {
                    LabeledContent("Schlüssel") { Text("\(credentials.keyID) · Team \(credentials.teamID)") }
                    if let error = bridge.push.lastError {
                        Text(error).foregroundStyle(Theme.orange)
                    }
                    Button("Schlüssel entfernen", role: .destructive) { bridge.push.removeKey() }
                } else {
                    TextField("Team-ID", text: $teamID)
                    Button("Push-Schlüssel (.p8) wählen …") { importingKey = true }
                        .disabled(teamID.isEmpty)
                    if let keyError { Text(keyError).foregroundStyle(Theme.orange) }
                }
            } header: {
                Text("Benachrichtigungen & Live-Aktivitäten")
            } footer: {
                Text("Einmalig nötig, damit der Mac dem iPhone Benachrichtigungen schicken darf: developer.apple.com → Certificates, Identifiers & Profiles → Keys → „+“ → „Apple Push Notifications service (APNs)“ aktivieren → Datei „AuthKey_….p8“ laden und hier auswählen.")
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $importingKey, allowedContentTypes: [UTType(filenameExtension: "p8") ?? .data]) { result in
            switch result {
            case .success(let url):
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                do {
                    try bridge.push.importKey(from: url, teamID: teamID.trimmingCharacters(in: .whitespaces))
                    keyError = nil
                } catch {
                    keyError = error.localizedDescription
                }
            case .failure(let error):
                keyError = error.localizedDescription
            }
        }
    }

    @ViewBuilder private var statusText: some View {
        switch bridge.serverState {
        case .stopped: Text("aus").foregroundStyle(.secondary)
        case .starting: Text("startet …").foregroundStyle(.secondary)
        case .listening(let port): Text("bereit · Port \(port)").foregroundStyle(Theme.green)
        case .failed(let message): Text(message).foregroundStyle(Theme.orange)
        }
    }
}
