import SwiftUI

/// Die Zentrale: Aufgabe beschreiben, Vorschlag mit Modell und Kosten prüfen, starten.
struct ZentraleView: View {
    @Environment(CompanionModel.self) private var model
    @State private var projectID: String?

    private var messages: [CompanionZentraleMessage] { model.snapshot?.zentrale ?? [] }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if messages.isEmpty && model.queuedZentrale.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Was soll erledigt werden?").font(.title3.weight(.semibold))
                                Text("Die Zentrale wählt Agenten und Modelle, schätzt die Kosten und verteilt große Aufgaben. Mit „sag Bescheid“ bekommst du eine Benachrichtigung.")
                                    .font(.footnote).foregroundStyle(Palette.secondary)
                            }
                            .padding(.top, 20)
                        }
                        ForEach(messages) { message in
                            ZentraleMessageView(message: message).id(message.id)
                        }
                        ForEach(model.queuedZentrale) { item in
                            if case .zentrale(_, let text, _, _) = item {
                                HStack {
                                    Spacer(minLength: 40)
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text(text).padding(12)
                                            .background(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4])))
                                        Label("wartet auf den Mac", systemImage: "clock").font(.caption2).foregroundStyle(Palette.orange)
                                    }
                                }
                            }
                        }
                        if model.snapshot?.zentraleThinking == true && model.isConnected {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small).tint(Palette.orange)
                                Text("Die Zentrale denkt nach …").font(.footnote).foregroundStyle(Palette.secondary)
                            }
                        }
                        if let error = model.snapshot?.zentraleError, model.isConnected {
                            Text(error).font(.footnote).foregroundStyle(Palette.orange)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding()
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: messages.count) { _, _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            .background(Palette.black)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    projectBar
                    Composer(placeholder: "Aufgabe für die Zentrale …") { text in
                        await model.sendToZentrale(text, projectID: projectID)
                    }
                }
            }
            .navigationTitle("Zentrale")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Neu", systemImage: "square.and.pencil") { Task { await model.newZentraleConversation() } }
                        .disabled(!model.isConnected)
                }
            }
            .onAppear { if projectID == nil { projectID = model.snapshot?.selectedProjectID } }
        }
    }

    private var projectBar: some View {
        Menu {
            ForEach(model.projects.filter { !$0.isMac }) { project in
                Button(project.name) { projectID = project.id }
            }
        } label: {
            HStack(spacing: 8) {
                if let project = projectID.flatMap({ model.project($0) }) {
                    ProjectIconView(project, size: 22)
                    Text("für \(project.name)").font(.caption.weight(.medium))
                } else {
                    Text("App wählen").font(.caption.weight(.medium))
                }
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
                Spacer()
                if let spent = model.snapshot?.spentToday, spent > 0 {
                    Text("heute \(spent.usd)").font(.caption2).foregroundStyle(Palette.tertiary)
                }
            }
            .foregroundStyle(Palette.secondary)
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .background(.bar)
    }
}

private struct ZentraleMessageView: View {
    @Environment(CompanionModel.self) private var model
    let message: CompanionZentraleMessage
    @State private var launching = false

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(message.text).padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.lift))
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                if !message.text.isEmpty { RichText(text: message.text) }
                if let proposal = message.proposal {
                    Card {
                        if let title = proposal.title { Text(title).font(.headline) }
                        if let analysis = proposal.analysis { Text(analysis).font(.footnote).foregroundStyle(Palette.secondary) }
                        ForEach(Array(proposal.tasks.enumerated()), id: \.offset) { _, task in
                            HStack(alignment: .firstTextBaseline) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(task.title).font(.subheadline.weight(.medium))
                                    Text("\(task.agent) · \(task.model)").font(.caption).foregroundStyle(Palette.tertiary)
                                }
                                Spacer()
                                if let cost = task.estimatedCostUSD { Text("≈ \(cost.usd)").font(.caption).foregroundStyle(Palette.secondary) }
                            }
                        }
                        HStack {
                            if let cost = proposal.estimatedCostUSD { Tag(text: "≈ \(cost.usd)") }
                            if let minutes = proposal.estimatedMinutes { Tag(text: "≈ \(Int(minutes)) min") }
                            Spacer()
                            if message.launched {
                                Label("gestartet", systemImage: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(Palette.green)
                            } else {
                                Button {
                                    launching = true
                                    Task { await model.launch(message); launching = false }
                                } label: {
                                    if launching { ProgressView() } else { Text("Starten").fontWeight(.semibold) }
                                }
                                .buttonStyle(.borderedProminent)
                                .foregroundStyle(Palette.black)
                                .disabled(!model.isConnected || launching)
                            }
                        }
                    }
                }
            }
        }
    }
}
