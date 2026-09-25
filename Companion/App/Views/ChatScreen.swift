import SwiftUI
import UIKit

/// Ein Chat in einer App – wie am Mac, live mitlesen und weiterschreiben.
struct ChatScreen: View {
    @Environment(CompanionModel.self) private var model
    let projectID: String
    @State var sessionID: String?

    init(projectID: String, sessionID: String?) {
        self.projectID = projectID
        _sessionID = State(initialValue: sessionID)
    }

    private var chat: CompanionChat? {
        guard let sessionID, model.chat?.sessionID == sessionID else { return nil }
        return model.chat
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if sessionID == nil && queued.isEmpty {
                        intro
                    }
                    ForEach(chat?.messages ?? []) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    ForEach(queued) { item in
                        if case .chat(_, _, _, let text, _) = item {
                            QueuedBubble(text: text)
                        }
                    }
                    if let activity = chat?.activity, chat?.busy == true {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).tint(Palette.active)
                            Text(activity).font(.footnote).foregroundStyle(Palette.secondary)
                        }
                        .id("activity")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chat?.messages.last?.text.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat?.messages.count) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
        .background(Palette.black)
        .safeAreaInset(edge: .bottom) {
            Composer(
                placeholder: model.isConnected ? "Nachricht … („sag Bescheid, wenn fertig“)" : "Wird gesendet, sobald der Mac da ist …",
                busy: chat?.busy ?? false,
                onStop: { if let sessionID { Task { await model.abortChat(projectID: projectID, sessionID: sessionID) } } }
            ) { text in
                let id = await model.sendChat(text, projectID: projectID, sessionID: sessionID)
                if sessionID == nil, let id {
                    sessionID = id
                    await model.openChat(projectID: projectID, sessionID: id)
                }
            }
        }
        .navigationTitle(chat?.title ?? (sessionID == nil ? "Neuer Chat" : "Chat"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let sessionID {
                ToolbarItem(placement: .topBarTrailing) {
                    let notify = chat?.notify ?? false
                    Button {
                        Task { await model.setNotify(!notify, target: .session(projectID: projectID, sessionID: sessionID)) }
                    } label: {
                        Image(systemName: notify ? "bell.fill" : "bell")
                    }
                    .disabled(!model.isConnected)
                }
            }
        }
        .task(id: sessionID) {
            if let sessionID { await model.openChat(projectID: projectID, sessionID: sessionID) }
        }
        .onChange(of: model.isConnected) { _, connected in
            if connected, let sessionID { Task { await model.openChat(projectID: projectID, sessionID: sessionID) } }
        }
        .onDisappear { Task { await model.closeChat() } }
    }

    private var queued: [OutboxItem] { model.queuedChats(projectID: projectID, sessionID: sessionID) }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.project(projectID)?.isMac == true ? "Was soll der Mac erledigen?" : "Was soll an der App passieren?")
                .font(.title3.weight(.semibold))
            Text("Der Agent arbeitet auf dem Mac mit allen Werkzeugen, Konnektoren und MCP-Servern. Schreib „sag Bescheid, wenn fertig“, dann bekommst du eine Benachrichtigung – auch bei Rückfragen.")
                .font(.footnote)
                .foregroundStyle(Palette.secondary)
        }
        .padding(.top, 20)
    }
}

private struct MessageBubble: View {
    let message: CompanionChatMessage
    @State private var showSteps = false

    var body: some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Palette.lift))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !message.steps.isEmpty {
                    Button {
                        withAnimation { showSteps.toggle() }
                    } label: {
                        Label("\(message.steps.count) Schritte", systemImage: showSteps ? "chevron.down" : "chevron.right")
                            .font(.caption)
                            .foregroundStyle(Palette.tertiary)
                    }
                    if showSteps {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(message.steps.enumerated()), id: \.offset) { _, step in
                                Text("· " + step).font(.caption.monospaced()).foregroundStyle(Palette.tertiary)
                            }
                        }
                    }
                }
                if !message.text.isEmpty {
                    RichText(text: message.text).foregroundStyle(Palette.text)
                }
                ForEach(Array(message.images.enumerated()), id: \.offset) { _, data in
                    if let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 420)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                if let error = message.error {
                    Text(error).font(.footnote).foregroundStyle(Palette.red)
                }
                if message.completed, let cost = message.costUSD, cost > 0 {
                    Text([message.agent, message.model, cost.euro].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2).foregroundStyle(Palette.tertiary)
                }
            }
        }
    }
}

private struct QueuedBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4])))
                Label("wartet auf den Mac", systemImage: "clock").font(.caption2).foregroundStyle(Palette.secondary)
            }
        }
    }
}
