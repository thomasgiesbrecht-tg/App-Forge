import SwiftUI

struct MessageRow: View {
    let message: ChatMessage
    var isQueued = false
    var isStreaming = false
    var canRewind = false
    var onRevert: (() -> Void)? = nil
    var onEdit: (() -> Void)? = nil

    var body: some View {
        if message.info.isUser, let (kind, prompt) = MediaStudio.parse(userText.components(separatedBy: MediaStudio.fileMarker)[0]) {
            MediaMessageView(
                kind: kind, prompt: prompt,
                imagePart: message.parts.first(where: \.isImage),
                fileURL: MediaStudio.fileURL(in: userText)
            )
        } else if message.info.isUser {
            UserBubble(
                text: userText,
                files: message.parts.filter { $0.type == "file" },
                isQueued: isQueued,
                canRewind: canRewind,
                onRevert: onRevert,
                onEdit: onEdit
            )
        } else {
            VStack(alignment: .leading, spacing: 12) {
                let visibleParts = message.parts.filter(\.isVisible)
                ForEach(visibleParts) { part in
                    PartView(part: part, showsCaret: isStreaming && part.id == visibleParts.last(where: { $0.type == "text" })?.id)
                        .transition(.riseIn)
                }
                if message.info.wasAborted {
                    Label("Abgebrochen", systemImage: "stop.circle")
                        .font(Theme.Fonts.sans(11))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let error = message.info.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Theme.Fonts.small)
                        .foregroundStyle(Theme.clay)
                        .textSelection(.enabled)
                }
                if let model = message.info.modelLabel, message.info.time.completed != nil, !visibleParts.isEmpty {
                    Text(footer(model: model))
                        .font(Theme.Fonts.sans(10))
                        .tracking(0.4)
                        .foregroundStyle(Theme.textTertiary.opacity(0.8))
                        .transition(.opacity)
                }
            }
            .animation(Theme.Motion.spring, value: message.parts.count)
            .animation(Theme.Motion.gentle, value: message.info.time.completed)
        }
    }

    private var userText: String {
        message.parts.filter { $0.type == "text" && $0.synthetic != true }.compactMap(\.text).joined(separator: "\n")
    }

    private func footer(model: String) -> String {
        var items = [model]
        if let tokens = message.info.tokens {
            items.append("\(Int(tokens.input + tokens.output)) Tokens")
        }
        if let cost = message.info.cost, cost > 0 {
            items.append(cost.formatted(.currency(code: "USD").precision(.fractionLength(4))))
        }
        return items.joined(separator: "  ·  ")
    }
}

private extension Part {
    var isVisible: Bool {
        switch type {
        case "text", "reasoning": !(text ?? "").isEmpty && synthetic != true
        case "tool", "file": true
        default: false
        }
    }
}

// MARK: Nutzer

private struct UserBubble: View {
    let text: String
    let files: [Part]
    let isQueued: Bool
    let canRewind: Bool
    let onRevert: (() -> Void)?
    let onEdit: (() -> Void)?
    @State private var hovering = false
    @State private var confirmRevert = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !files.isEmpty {
                HStack(spacing: 8) {
                    Spacer(minLength: 90)
                    ForEach(files) { file in
                        SentAttachment(part: file)
                    }
                }
            }
            bubble
            if canRewind, onRevert != nil || onEdit != nil {
                HStack(spacing: 4) {
                    if let onEdit {
                        Button(action: onEdit) { Label("Bearbeiten", systemImage: "pencil") }
                            .buttonStyle(PillButtonStyle())
                            .help("Ab hier zurücksetzen und die Nachricht neu formulieren")
                    }
                    if onRevert != nil {
                        Button { confirmRevert = true } label: { Label("Ab hier zurücksetzen", systemImage: "arrow.uturn.backward") }
                            .buttonStyle(PillButtonStyle())
                            .help("Chat und Dateien auf den Stand vor dieser Nachricht zurücksetzen")
                    }
                }
                .scaleEffect(0.9, anchor: .trailing)
                .opacity(hovering ? 1 : 0)
                .offset(y: hovering ? 0 : -4)
            }
        }
        .onHover { hovering = $0 }
        .animation(Theme.Motion.snappy, value: hovering)
        .confirmationDialog("Auf den Stand vor dieser Nachricht zurücksetzen?", isPresented: $confirmRevert) {
            Button("Zurücksetzen") { onRevert?() }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Dateiänderungen ab hier werden rückgängig gemacht. Du kannst das wiederherstellen, solange du keine neue Nachricht schickst.")
        }
    }

    private var bubble: some View {
        HStack(alignment: .bottom, spacing: 10) {
            Spacer(minLength: 90)
            if isQueued {
                HStack(spacing: 6) {
                    BreathingDots(color: Theme.smoke)
                        .scaleEffect(0.7)
                    Text("wartet")
                        .font(Theme.Fonts.sans(10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
            Text(text)
                .font(Theme.Fonts.sans(13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glass(cornerRadius: 18, tint: isQueued ? Theme.forest : Theme.ember, tintOpacity: isQueued ? 0.2 : 0.35, shadow: false)
                .overlay {
                    if isQueued {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.ochre.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .opacity(isQueued ? 0.75 : 1)
        }
        .animation(Theme.Motion.spring, value: isQueued)
    }
}

/// Verschickter Anhang in der Nutzer-Nachricht.
private struct SentAttachment: View {
    let part: Part

    private var image: NSImage? { ImageCache.image(for: part) }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
                .help(part.filename ?? "Bild")
        } else {
            Label(part.filename ?? "Datei", systemImage: "doc.text")
                .font(Theme.Fonts.sans(11))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .glass(cornerRadius: 10, tintOpacity: 0.25, shadow: false)
        }
    }
}

/// Dekodierte Anhang-Bilder zwischenspeichern – Base64 bei jedem Neuzeichnen zu dekodieren wäre teuer.
@MainActor
enum ImageCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(for part: Part) -> NSImage? {
        guard part.isImage, let url = part.url else { return nil }
        if let cached = cache.object(forKey: part.id as NSString) { return cached }
        guard let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: part.id as NSString)
        return image
    }
}

// MARK: Antwort-Teile

private struct PartView: View {
    let part: Part
    var showsCaret = false

    var body: some View {
        switch part.type {
        case "text":
            MarkdownText(text: part.text ?? "", showsCaret: showsCaret)
        case "reasoning":
            ReasoningView(text: part.text ?? "")
        case "tool" where part.tool == "task":
            SubagentCard(part: part)
        case "tool":
            ToolCard(part: part)
        case "file":
            Label(part.filename ?? "Datei", systemImage: "doc")
                .font(Theme.Fonts.small)
                .foregroundStyle(Theme.textSecondary)
        default:
            EmptyView()
        }
    }
}

private struct ReasoningView: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Theme.Motion.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Gedankengang")
                        .font(Theme.Fonts.sans(11.5))
                        .tracking(0.3)
                }
                .foregroundStyle(Theme.textTertiary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Text(text)
                    .font(Theme.Fonts.sans(12.5, .light))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.moss.opacity(0.5)).frame(width: 1)
                    }
                    .transition(.asymmetric(insertion: .riseIn, removal: .opacity))
            }
        }
    }
}

// MARK: Tool-Aufrufe

private struct ToolCard: View {
    let part: Part
    @State private var expanded = false
    @State private var hovering = false

    private var status: String { part.state?.status ?? "pending" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.spring) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    statusIcon
                        .frame(width: 16, height: 16)
                    Text(ToolNames.displayName(part.tool ?? "tool"))
                        .font(Theme.Fonts.sans(12, .medium))
                        .foregroundStyle(Theme.textPrimary)
                    if let title = part.state?.title, !title.isEmpty {
                        Text(title)
                            .font(Theme.Fonts.mono(11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                        .opacity(hovering || expanded ? 1 : 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = part.state?.input, input != .null {
                        CodeBlock(title: "Eingabe", code: input.prettyPrinted)
                    }
                    if let output = part.state?.output, !output.isEmpty {
                        CodeBlock(title: "Ausgabe", code: String(output.prefix(20_000)))
                    }
                    if let error = part.state?.error {
                        CodeBlock(title: "Fehler", code: error)
                    }
                }
                .padding([.horizontal, .bottom], 10)
                .transition(.asymmetric(insertion: .riseIn, removal: .opacity))
            }
        }
        .glass(cornerRadius: 14, tint: status == "error" ? Theme.clay : Theme.forest, tintOpacity: status == "error" ? 0.12 : 0.3, shadow: false)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.spring, value: status)
    }

    @ViewBuilder private var statusIcon: some View {
        switch status {
        case "completed":
            DrawnCheckmark(size: 13)
                .transition(.scale.combined(with: .opacity))
        case "error":
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.clay)
                .transition(.scale.combined(with: .opacity))
        case "running":
            ForgeSpinner(size: 13)
                .transition(.opacity)
        default:
            Circle()
                .strokeBorder(Theme.smoke, lineWidth: 1)
                .frame(width: 10, height: 10)
        }
    }
}

enum ToolNames {
    static func displayName(_ tool: String) -> String {
        switch tool {
        case "bash": "Terminal"
        case "read": "Datei lesen"
        case "write": "Datei schreiben"
        case "edit", "multiedit", "apply_patch", "patch": "Datei bearbeiten"
        case "glob", "list": "Dateien suchen"
        case "grep": "Code durchsuchen"
        case "webfetch": "Webseite laden"
        case "websearch": "Websuche"
        case "todowrite", "todoread": "Aufgabenliste"
        case "task": "Unteragent"
        case "skill": "Skill laden"
        default:
            // MCP-Tools kommen als "<server>_<tool>"
            if tool.hasPrefix("xcodebuildmcp_") { "XcodeBuild · " + tool.dropFirst("xcodebuildmcp_".count) }
            else if tool.hasPrefix("xcode_") { "Xcode · " + tool.dropFirst("xcode_".count) }
            else { tool }
        }
    }
}
