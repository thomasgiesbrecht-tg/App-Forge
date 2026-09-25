import AppKit
import SwiftUI

/// Projektwissen der geöffneten App – rechte Seitenleiste.
struct KnowledgePanel: View {
    @Environment(AppStore.self) private var store

    private var knowledge: KnowledgeService { store.knowledge }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let project = store.selectedProject {
                content(project)
            } else {
                ContentUnavailableView {
                    Label("Kein Projekt", systemImage: "books.vertical")
                } description: {
                    Text("Öffne links eine App, um ihr Projektwissen zu sehen.")
                }
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func content(_ project: String) -> some View {
        let status = knowledge.status(for: project)
        let running = status.phase == .building || status.phase == .updating

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle().fill(color(status)).frame(width: 7, height: 7)
                Text(title(status)).font(Theme.Fonts.sans(13, .medium)).foregroundStyle(Theme.textPrimary)
                Spacer()
                if running { ProgressView().controlSize(.small) }
            }
            if let activity = status.activity, running {
                Text(activity).font(Theme.Fonts.sans(11.5)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            if let cost = status.costUSD, cost > 0 {
                Text("bisher \(Money.format(cost))").font(Theme.Fonts.sans(10.5)).foregroundStyle(Theme.textTertiary)
            }
            if case .failed(let message) = status.phase {
                Text(message).font(Theme.Fonts.sans(11)).foregroundStyle(Theme.red)
            }
            if let stand = status.stand {
                Text("Stand \(stand.updatedAt.formatted(date: .abbreviated, time: .shortened)) · \(stand.updates) Aktualisierungen")
                    .font(Theme.Fonts.sans(10.5)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raise))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))

        if status.stand == nil {
            Text("Der Chronist liest die App einmal gründlich und schreibt auf, was sie tut, wie alles zusammenhängt und warum es so gebaut ist – aus Code, Commits, Chats und Aufträgen. Danach hält AppForge das Wissen bei jeder Änderung selbst aktuell, und jeder Agent kennt die App ohne langes Suchen.")
                .font(Theme.Fonts.sans(11.5))
                .foregroundStyle(Theme.textSecondary)
            Button {
                Task { await knowledge.build(project) }
            } label: {
                Label("Wissen aufbauen", systemImage: "books.vertical").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(running || knowledge.isRunning || store.client == nil)
            Text("Einmalig mit \(knowledge.buildModel?.label ?? store.selectedModel?.label ?? "dem Chat-Modell") – je nach Größe der App einige Cent bis wenige Euro.")
                .font(Theme.Fonts.sans(10.5))
                .foregroundStyle(Theme.textTertiary)
        } else {
            HStack {
                Button("Jetzt aktualisieren") { Task { await knowledge.update(project) } }
                    .disabled(running || knowledge.isRunning || store.client == nil)
                Menu {
                    Button("Neu aufbauen") { Task { await knowledge.build(project) } }
                    Button("Ordner im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([KnowledgeService.folderURL(project)])
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(running)
            }
            files(project)
            Text("Frag im Chat den Agenten „Projekt-Kenner“ oder schreib @kenner – alle Agenten kennen die Kurzfassung automatisch.")
                .font(Theme.Fonts.sans(10.5))
                .foregroundStyle(Theme.textTertiary)
        }

        @Bindable var knowledge = knowledge
        Toggle("Bei Änderungen automatisch aktualisieren", isOn: $knowledge.autoUpdate)
            .font(Theme.Fonts.sans(11.5))
            .toggleStyle(.switch)
            .controlSize(.mini)
        Spacer(minLength: 0)
    }

    private func files(_ project: String) -> some View {
        let names = [
            ("kurzfassung.md", "Kurzfassung"), ("ueberblick.md", "Überblick"), ("architektur.md", "Architektur"),
            ("funktionen.md", "Funktionen"), ("entscheidungen.md", "Entscheidungen"), ("dateien.md", "Dateikarte"),
            ("chronik.md", "Chronik"), ("offen.md", "Offene Punkte"),
        ]
        let folder = KnowledgeService.folderURL(project)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(names, id: \.0) { file, title in
                let url = folder.appending(path: file)
                if FileManager.default.fileExists(atPath: url.path) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        HStack {
                            Image(systemName: "doc.text").foregroundStyle(Theme.textTertiary)
                            Text(title).foregroundStyle(Theme.textSecondary)
                            Spacer()
                        }
                        .font(Theme.Fonts.sans(12))
                        .padding(.vertical, 5)
                        .padding(.horizontal, 6)
                    }
                    .buttonStyle(RowButtonStyle())
                }
            }
        }
    }

    private func title(_ status: KnowledgeService.Status) -> String {
        switch status.phase {
        case .building: "Wissen wird aufgebaut"
        case .updating: "Wissen wird aktualisiert"
        case .failed: "Fehlgeschlagen"
        case .idle:
            if status.stand == nil { "Noch kein Projektwissen" }
            else if status.outdated { knowledge.autoUpdate ? "Änderungen erkannt – wird bald aktualisiert" : "Nicht mehr aktuell" }
            else { "Wissen ist aktuell" }
        }
    }

    private func color(_ status: KnowledgeService.Status) -> Color {
        switch status.phase {
        case .building, .updating: Theme.active
        case .failed: Theme.red
        case .idle: status.stand == nil ? Theme.textTertiary : (status.outdated ? Theme.textSecondary : Theme.green)
        }
    }
}
