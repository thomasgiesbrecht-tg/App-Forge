import SwiftUI

/// Zeigt oben, ob der Mac erreichbar ist. Offline kann trotzdem alles geschrieben werden.
struct ConnectionBanner: View {
    @Environment(CompanionModel.self) private var model

    var body: some View {
        switch model.connection {
        case .connected:
            EmptyView()
        case .searching:
            banner("Verbinde mit \(model.macName) …", symbol: "antenna.radiowaves.left.and.right", color: Palette.secondary, spinning: true)
        case .offline:
            let waiting = model.outbox.count + model.pendingIdeas.count
            banner(
                "\(model.macName) nicht erreichbar" + (waiting > 0 ? " · \(waiting) warten" : ""),
                detail: "Du kannst trotzdem alles schreiben – es wird gesendet, sobald der Mac wieder da ist.",
                symbol: "moon.zzz.fill", color: Palette.red
            )
            .onTapGesture { model.reconnect() }
        case .unpaired:
            banner("Noch nicht mit dem Mac gekoppelt", detail: "Tippe auf „Mac“ und scanne den QR-Code aus AppForge.",
                   symbol: "qrcode", color: Palette.orange)
                .onTapGesture { model.selectedTab = .mac }
        }
    }

    private func banner(_ title: String, detail: String? = nil, symbol: String, color: Color, spinning: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            if spinning { ProgressView().controlSize(.small) } else { Image(systemName: symbol).foregroundStyle(color) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.text)
                if let detail { Text(detail).font(.caption).foregroundStyle(Palette.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.lift))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Palette.line))
        .padding(.horizontal)
        .padding(.top, 4)
    }
}

/// Eingabezeile mit Diktat und Senden – für Chats, Zentrale und Fragen an den Ideen-Agenten.
struct Composer: View {
    var placeholder: String
    var busy = false
    var onStop: (() -> Void)?
    var onSend: (String) async -> Void

    @State private var text = ""
    @State private var base = ""
    @State private var speech = SpeechRecorder()
    @State private var sending = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let error = speech.error {
                Text(error).font(.caption).foregroundStyle(Palette.red)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...8)
                    .focused($focused)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.lift))
                    .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(speech.isRecording ? Palette.accent : Palette.line))

                Button {
                    Task {
                        if !speech.isRecording { base = text.isEmpty ? "" : text + " " }
                        await speech.toggle()
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "waveform" : "mic.fill")
                        .symbolEffect(.variableColor.iterative, isActive: speech.isRecording)
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(speech.isRecording ? Palette.accent.opacity(0.25) : Palette.lift))
                }
                .foregroundStyle(speech.isRecording ? Palette.accent : Palette.secondary)

                if busy && text.isEmpty, let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Palette.lift))
                    }
                    .foregroundStyle(Palette.red)
                } else {
                    Button {
                        let message = text
                        speech.stop()
                        text = ""
                        base = ""
                        sending = true
                        Task {
                            await onSend(message)
                            sending = false
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .fontWeight(.bold)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(text.isEmpty ? Palette.lift : Palette.accent))
                    }
                    .foregroundStyle(text.isEmpty ? Palette.tertiary : Palette.black)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .onChange(of: speech.transcript) { _, transcript in
            if speech.isRecording || !transcript.isEmpty { text = base + transcript }
        }
    }
}

/// Markdown-Text der Agenten (Fett, Code, Links) – Absätze bleiben erhalten.
struct RichText: View {
    let text: String

    var body: some View {
        if let attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

struct Tag: View {
    let text: String
    var color: Color = Palette.secondary

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Palette.lift))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.raise))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line))
    }
}

