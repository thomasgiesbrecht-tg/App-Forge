import SwiftUI

/// Sichtbare Delegation: Ein Agent beauftragt einen Unteragenten. Die Karte zeigt live,
/// woran der Unteragent gerade arbeitet, und lässt sich zum vollständigen Verlauf aufklappen.
struct SubagentCard: View {
    @Environment(AppStore.self) private var store
    let part: Part
    @State private var expanded = false

    private var agentName: String { part.state?.input?["subagent_type"]?.stringValue ?? "unteragent" }
    private var task: String { part.state?.input?["description"]?.stringValue ?? part.state?.title ?? "Auftrag" }
    private var status: String { part.state?.status ?? "pending" }
    private var childMessages: [ChatMessage] { part.childSessionID.flatMap { store.messages[$0] } ?? [] }

    /// Letzte sichtbare Tätigkeit des Unteragenten (Werkzeug oder Text).
    private var currentActivity: String? {
        for message in childMessages.reversed() where !message.info.isUser {
            for part in message.parts.reversed() {
                if part.type == "tool", let tool = part.tool {
                    let title = part.state?.title ?? ""
                    return ToolNames.displayName(tool) + (title.isEmpty ? "" : " · \(title)")
                }
                if part.type == "text", let text = part.text, !text.isEmpty {
                    return text.replacingOccurrences(of: "\n", with: " ")
                }
            }
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Theme.Motion.spring) { expanded.toggle() }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    AgentAvatar(name: agentName, working: status == "running")
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("@\(agentName)")
                                .font(Theme.Fonts.sans(12, .semibold))
                                .foregroundStyle(Theme.ochre)
                            Text(task)
                                .font(Theme.Fonts.sans(12))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                        }
                        Group {
                            switch status {
                            case "running":
                                Text(currentActivity ?? "arbeitet …")
                            case "completed":
                                Text("fertig · \(childMessages.filter { !$0.info.isUser }.count) Schritte")
                            case "error":
                                Text(part.state?.error ?? "fehlgeschlagen")
                            default:
                                Text("wartet")
                            }
                        }
                        .font(Theme.Fonts.sans(11))
                        .foregroundStyle(status == "error" ? Theme.clay : Theme.textTertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                    Group {
                        switch status {
                        case "completed": DrawnCheckmark(size: 13)
                        case "running": ForgeSpinner(size: 13)
                        case "error": Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.clay)
                        default: EmptyView()
                        }
                    }
                    .frame(width: 16, height: 16)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 14) {
                    if childMessages.isEmpty {
                        ShimmerText(text: "Verlauf wird geladen …")
                    }
                    ForEach(childMessages) { message in
                        MessageRow(message: message)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .padding(.leading, 30)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.ochre.opacity(0.25)).frame(width: 1).padding(.leading, 27).padding(.bottom, 14)
                }
                .transition(.asymmetric(insertion: .riseIn, removal: .opacity))
            }
        }
        .glass(cornerRadius: 16, tint: Theme.ember, tintOpacity: status == "running" ? 0.3 : 0.15, shadow: false)
        .overlay {
            if status == "running" {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.ochre.opacity(0.35), lineWidth: 1)
            }
        }
        .animation(Theme.Motion.spring, value: status)
        .task(id: part.childSessionID) {
            if let child = part.childSessionID { await store.loadChildSession(child) }
        }
    }
}

/// Monogramm eines Agenten mit Glut-Ring, solange er arbeitet.
struct AgentAvatar: View {
    let name: String
    var working = false
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().fill(Theme.pine)
            Text(String(name.prefix(1)).uppercased())
                .font(Theme.Fonts.sans(12, .medium))
                .foregroundStyle(Theme.sand)
            if working {
                Circle()
                    .trim(from: 0, to: 0.7)
                    .stroke(AngularGradient(colors: [Theme.ochre.opacity(0), Theme.ochre], center: .center), lineWidth: 1.5)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1.4).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            } else {
                Circle().strokeBorder(.white.opacity(0.1))
            }
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: Änderungen

/// „3 Dateien geändert · +12 −4“ unter einer Antwort.
struct ChangesChip: View {
    let changes: [FileChange]
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ochre)
                Text(changes.count == 1 ? changes[0].name : "\(changes.count) Dateien geändert")
                    .font(Theme.Fonts.sans(11.5))
                    .foregroundStyle(Theme.textSecondary)
                ChangeCounts(additions: changes.reduce(0) { $0 + $1.additions }, deletions: changes.reduce(0) { $0 + $1.deletions })
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .buttonStyle(RowButtonStyle())
        .glass(cornerRadius: 12, tintOpacity: 0.25, shadow: false)
        .transition(.riseIn)
    }
}

struct ChangeCounts: View {
    let additions: Double
    let deletions: Double

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(Int(additions))").foregroundStyle(Theme.sage)
            Text("−\(Int(deletions))").foregroundStyle(Theme.clay)
        }
        .font(Theme.Fonts.mono(10.5, .medium))
        .contentTransition(.numericText())
    }
}

/// Unified Diff, farbig: grün hinzugefügt, lehmrot entfernt.
struct DiffText: View {
    let patch: String

    private struct Line: Identifiable {
        let id: Int
        let text: String
        let kind: Kind
        enum Kind { case add, remove, hunk, context, meta }
    }

    private var lines: [Line] {
        patch.components(separatedBy: "\n").enumerated().compactMap { index, text in
            let kind: Line.Kind
            if text.hasPrefix("+++") || text.hasPrefix("---") || text.hasPrefix("diff ") || text.hasPrefix("index ")
                || text.hasPrefix("Index:") || text.hasPrefix("====") { kind = .meta }
            else if text.hasPrefix("@@") { kind = .hunk }
            else if text.hasPrefix("+") { kind = .add }
            else if text.hasPrefix("-") { kind = .remove }
            else { kind = .context }
            return kind == .meta ? nil : Line(id: index, text: text, kind: kind)
        }
    }

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(Theme.Fonts.mono(11))
                        .foregroundStyle(color(line.kind))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(background(line.kind))
                }
            }
            .padding(.vertical, 6)
            .textSelection(.enabled)
        }
        .scrollIndicators(.never)
        .background(Theme.void.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline))
    }

    private func color(_ kind: Line.Kind) -> Color {
        switch kind {
        case .add: Theme.sage
        case .remove: Theme.clay
        case .hunk: Theme.ochre.opacity(0.7)
        case .context, .meta: Theme.sand.opacity(0.65)
        }
    }

    private func background(_ kind: Line.Kind) -> Color {
        switch kind {
        case .add: Theme.moss.opacity(0.18)
        case .remove: Theme.clay.opacity(0.12)
        default: .clear
        }
    }
}
