import SwiftUI
import UIKit

/// Verbindung zum Mac, Kopplung und Simulator.
struct MacView: View {
    @Environment(CompanionModel.self) private var model
    @State private var pairingLink = ""
    @State private var pairingError: String?
    @State private var screenshot: UIImage?
    @State private var loadingShot = false
    @State private var confirmUnpair = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Mac", value: model.pairing?.macName ?? "nicht gekoppelt")
                    LabeledContent("Status") { status }
                    if let host = model.pairing?.remoteHost {
                        LabeledContent("Unterwegs über", value: host)
                    }
                    if let snapshot = model.snapshot {
                        LabeledContent("Engine", value: snapshot.engineRunning ? "läuft" : (snapshot.engineError ?? "gestoppt"))
                        LabeledContent("Freigaben", value: snapshot.permissionMode)
                    }
                    if let last = model.lastConnected, !model.isConnected {
                        LabeledContent("Zuletzt verbunden") { Text(last, style: .relative) }
                    }
                    if model.pairing != nil {
                        Button("Neu verbinden") { model.reconnect() }
                    }
                }

                if model.pairing == nil || !model.isConnected {
                    Section {
                        Text("In AppForge auf dem Mac: Einstellungen → iPhone. Den QR-Code mit der Kamera-App scannen – oder den Kopplungs-Link hier einfügen.")
                            .font(.footnote).foregroundStyle(Palette.secondary)
                        TextField("appforge-companion://pair?…", text: $pairingLink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        HStack {
                            PasteButton(payloadType: String.self) { strings in
                                if let first = strings.first { pairingLink = first }
                            }
                            Spacer()
                            Button("Koppeln") {
                                if let url = URL(string: pairingLink.trimmingCharacters(in: .whitespacesAndNewlines)), model.pair(with: url) {
                                    pairingLink = ""
                                    pairingError = nil
                                } else {
                                    pairingError = "Das ist kein gültiger Kopplungs-Link."
                                }
                            }
                            .disabled(pairingLink.isEmpty)
                        }
                        if let pairingError { Text(pairingError).foregroundStyle(Palette.orange) }
                    } header: {
                        Text(model.pairing == nil ? "Koppeln" : "Neu koppeln")
                    }
                }

                Section("Simulator") {
                    if let name = model.snapshot?.simulatorName, model.snapshot?.simulatorBooted == true {
                        LabeledContent("Läuft", value: name)
                    } else {
                        Text("Kein Simulator gestartet.").foregroundStyle(Palette.secondary)
                    }
                    Button {
                        Task { await loadScreenshot() }
                    } label: {
                        HStack {
                            Label("Screenshot holen", systemImage: "camera.viewfinder")
                            if loadingShot { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(!model.isConnected || loadingShot)
                    if let screenshot {
                        Image(uiImage: screenshot)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 520)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .frame(maxWidth: .infinity)
                    }
                }

                if model.pairing != nil {
                    Section {
                        Button("Kopplung entfernen", role: .destructive) { confirmUnpair = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.black)
            .navigationTitle("Mac")
            .confirmationDialog("Kopplung mit dem Mac entfernen?", isPresented: $confirmUnpair) {
                Button("Entfernen", role: .destructive) { model.unpair() }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.connection {
        case .connected: Label("verbunden", systemImage: "checkmark.circle.fill").foregroundStyle(Palette.green)
        case .searching: Text("sucht …").foregroundStyle(Palette.secondary)
        case .offline(let reason): Text(reason.map { "nicht erreichbar (\($0))" } ?? "nicht erreichbar").foregroundStyle(Palette.orange)
        case .unpaired: Text("nicht gekoppelt").foregroundStyle(Palette.secondary)
        }
    }

    private func loadScreenshot() async {
        loadingShot = true
        if let data = await model.screenshot() { screenshot = UIImage(data: data) }
        loadingShot = false
    }
}
