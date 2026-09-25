import SwiftUI

/// Einstellungen → Sparen: die Sparregeln und ein Bericht, ob sie wirken.
struct SavingsSettings: View {
    @Environment(AppStore.self) private var store
    @State private var cascade = Savings.cascade
    @State private var verify = Savings.verifyBuild
    @State private var smallModel = Savings.smallModel ?? ""
    @State private var steps = Savings.steps
    @State private var toolLines = Savings.toolOutputLines
    @State private var offPeakStart = Savings.offPeakStart
    @State private var offPeakEnd = Savings.offPeakEnd
    @State private var engineDirty = false

    private var dispatcher: Dispatcher { store.dispatcher }

    var body: some View {
        Form {
            Section {
                Toggle("Günstig zuerst, stärkeres Modell nur bei Fehlschlag", isOn: $cascade)
                    .onChange(of: cascade) { Savings.cascade = cascade }
                Toggle("Prüfschritt: wer Dateien ändert, muss bauen", isOn: $verify)
                    .onChange(of: verify) { Savings.verifyBuild = verify }
            } header: {
                Text("Regeln der Zentrale")
            } footer: {
                Text("Diese Regeln setzt AppForge selbst durch: Scheitern Build oder Tests, übergibt es einmal an das stärkere Modell. Hat ein Agent nie gebaut, fordert es ihn einmal dazu auf. Beides kostet nur dann etwas extra, wenn es eintritt.")
            }

            Section {
                Picker("Modell für Titel und Zusammenfassungen", selection: $smallModel) {
                    ForEach(ModelCatalog.entries(from: store.providers).sorted { $0.blendedPrice < $1.blendedPrice }, id: \.selection.label) { entry in
                        Text("\(entry.model.name) · \(Money.format(entry.inputPrice)) je Mio. Tokens").tag(entry.selection.label)
                    }
                    if smallModel.isEmpty { Text("automatisch").tag("") }
                }
                .onChange(of: smallModel) { Savings.smallModel = smallModel.isEmpty ? nil : smallModel; engineDirty = true }
                Stepper("Höchstens \(steps) Schritte je Agent", value: $steps, in: 20...300, step: 10)
                    .onChange(of: steps) { Savings.steps = steps; engineDirty = true }
                Stepper("Werkzeugausgaben ab \(toolLines) Zeilen kürzen", value: $toolLines, in: 100...2000, step: 100)
                    .onChange(of: toolLines) { Savings.toolOutputLines = toolLines; engineDirty = true }
                if engineDirty {
                    HStack {
                        Text(dispatcher.runningMissions.isEmpty ? "Wird nach einem Neustart der Engine wirksam." : "Wird nach einem Neustart wirksam – gerade laufen Aufträge.")
                            .font(Theme.Fonts.small)
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Jetzt neu starten") {
                            engineDirty = false
                            Task { await store.restartEngine() }
                        }
                        .disabled(!dispatcher.runningMissions.isEmpty)
                    }
                }
            } header: {
                Text("Grenzen der Engine")
            } footer: {
                Text("Außerdem immer an: lange Verläufe werden verdichtet und alte Werkzeugausgaben entfernt.")
            }

            Section {
                LabeledContent("Beginn") { timePicker($offPeakStart) }
                LabeledContent("Ende") { timePicker($offPeakEnd) }
            } header: {
                Text("Nachttarif (DeepSeek)")
            } footer: {
                Text("Nicht eilige Aufträge mit DeepSeek-Modellen können auf dieses Zeitfenster warten. Vorgabe ist 18:30–02:30 Uhr (16:30–00:30 UTC im Sommer). Prüfe die aktuellen Zeiten auf der Preisseite von DeepSeek.")
            }
            .onChange(of: offPeakStart) { Savings.offPeakStart = offPeakStart }
            .onChange(of: offPeakEnd) { Savings.offPeakEnd = offPeakEnd }

            SavingsReport(missions: dispatcher.missions)
        }
        .formStyle(.grouped)
    }

    private func timePicker(_ minutes: Binding<Int>) -> some View {
        Picker("", selection: minutes) {
            ForEach(Array(stride(from: 0, to: 24 * 60, by: 30)), id: \.self) { Text(Savings.clock($0)).tag($0) }
        }
        .labelsHidden()
        .frame(width: 100)
    }
}

/// Wirken die Regeln? Zwischenspeicher-Quote, Übergaben und Kosten je Modell.
private struct SavingsReport: View {
    let missions: [Mission]

    var body: some View {
        let experience = ModelCatalog.experience(from: missions).sorted { $0.value.runs > $1.value.runs }
        let input = missions.compactMap(\.inputTokens).reduce(0, +)
        let cached = missions.compactMap(\.cachedTokens).reduce(0, +)
        let escalations = missions.filter { $0.escalatedModel != nil }.count
        let verified = missions.filter { $0.verifySent == true }.count

        Section {
            LabeledContent("Zwischenspeicher") {
                if input + cached > 0 {
                    let rate = cached / (input + cached)
                    Text("\(Int(rate * 100)) % der Eingabe")
                        .foregroundStyle(rate < 0.3 ? Theme.red : Theme.textPrimary)
                } else {
                    Text("noch keine Daten").foregroundStyle(Theme.textTertiary)
                }
            }
            LabeledContent("An stärkeres Modell übergeben", value: "\(escalations)×")
            LabeledContent("Prüfschritt verlangt", value: "\(verified)×")
            ForEach(experience, id: \.key) { model, exp in
                VStack(alignment: .leading, spacing: 2) {
                    Text(model).font(Theme.Fonts.mono(11))
                    Text(exp.summary).font(Theme.Fonts.small).foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Sparbericht")
        } footer: {
            Text("Ein hoher Zwischenspeicher-Anteil heißt: der Anbieter berechnet den Großteil der Eingabe nur zu einem Bruchteil. Unter 30 % wird er rot – dann stimmt etwas nicht. Die Zentrale nutzt diese Werte, um Modelle zu wählen.")
        }
    }
}
