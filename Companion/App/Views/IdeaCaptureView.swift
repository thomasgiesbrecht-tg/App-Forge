import SwiftUI

/// Schnell eine Idee festhalten – sprechen oder schreiben. Wird sofort gespeichert,
/// auch ohne Verbindung, und vom Ideen-Agenten auf dem Mac eingeordnet.
struct IdeaCaptureView: View {
    @Environment(CompanionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var projectID: String
    let mode: CaptureMode

    @State private var text = ""
    @State private var base = ""
    @State private var speech = SpeechRecorder()
    @FocusState private var focused: Bool

    init(projectID: String, mode: CaptureMode) {
        _projectID = State(initialValue: projectID)
        self.mode = mode
    }

    private var project: CompanionProject? { model.project(projectID) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                projectPicker

                TextField("Deine Idee …", text: $text, axis: .vertical)
                    .font(.title3)
                    .lineLimit(4...12)
                    .focused($focused)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.lift))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(speech.isRecording ? Palette.orange : Palette.line))

                if let error = speech.error { Text(error).font(.footnote).foregroundStyle(Palette.orange) }

                HStack(spacing: 16) {
                    Button {
                        Task {
                            if !speech.isRecording {
                                base = text.isEmpty ? "" : text + " "
                                focused = false
                            }
                            await speech.toggle()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(speech.isRecording ? Palette.orange : Palette.lift)
                                .frame(width: 72, height: 72)
                                .scaleEffect(1 + CGFloat(speech.level) * 0.25)
                                .animation(.easeOut(duration: 0.1), value: speech.level)
                            Image(systemName: speech.isRecording ? "stop.fill" : "mic.fill")
                                .font(.title)
                                .foregroundStyle(speech.isRecording ? Palette.black : Palette.orange)
                        }
                    }
                    .accessibilityLabel(speech.isRecording ? "Aufnahme stoppen" : "Idee einsprechen")

                    Button(action: save) {
                        Label("Speichern", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 56)
                    }
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(Palette.black)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Text(model.isConnected ? "Der Ideen-Agent ordnet sie gleich ein – umgesetzt wird nichts." : "Mac nicht erreichbar – die Idee wird gespeichert und später übertragen.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding()
            .background(Palette.black)
            .navigationTitle("Neue Idee")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { speech.stop(); dismiss() } }
            }
            .onChange(of: speech.transcript) { _, transcript in
                if speech.isRecording || !transcript.isEmpty { text = base + transcript }
            }
            .task {
                SharedStore.markUsed(projectID)
                if mode == .speak { await speech.start() } else { focused = true }
            }
            .onDisappear { speech.stop() }
        }
    }

    private var projectPicker: some View {
        Menu {
            ForEach(model.projects) { project in
                Button(project.name) { projectID = project.id }
            }
        } label: {
            HStack(spacing: 12) {
                if let project { ProjectIconView(project, size: 40) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(project?.name ?? "App wählen").font(.headline).foregroundStyle(Palette.text)
                    Text("Idee für diese App").font(.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(Palette.tertiary)
            }
        }
    }

    private func save() {
        speech.stop()
        model.addIdea(text, projectID: projectID)
        dismiss()
    }
}
