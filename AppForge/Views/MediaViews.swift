import AVKit
import SwiftUI

/// Erkennt `/foto …` und `/video …` in Nutzer-Nachrichten und zeigt das erzeugte Medium groß an.
struct MediaMessageView: View {
    let kind: MediaKind
    let prompt: String
    let imagePart: Part?
    let fileURL: URL?
    @State private var hovering = false
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ochre)
                Text(kind.command)
                    .font(Theme.Fonts.mono(11.5, .medium))
                    .foregroundStyle(Theme.ochre)
                Text(prompt)
                    .font(Theme.Fonts.sans(12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            Group {
                switch kind {
                case .image:
                    if let image = imagePart.flatMap(ImageCache.image(for:)) ?? fileURL.flatMap(NSImage.init(contentsOf:)) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .onTapGesture(count: 2) { if let fileURL { NSWorkspace.shared.open(fileURL) } }
                    } else {
                        missing
                    }
                case .video:
                    if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
                        LoopingVideo(url: fileURL)
                            .aspectRatio(16 / 9, contentMode: .fit)
                    } else {
                        missing
                    }
                }
            }
            .frame(maxWidth: 560, maxHeight: 520, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
            .overlay(alignment: .bottomTrailing) { actions.opacity(hovering ? 1 : 0).padding(10) }
            .onHover { hovering = $0 }
            .animation(Theme.Motion.snappy, value: hovering)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var missing: some View {
        Label("Datei nicht mehr vorhanden", systemImage: "questionmark.square.dashed")
            .font(Theme.Fonts.small)
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 280, height: 160)
            .glass(cornerRadius: 16, tintOpacity: 0.2, shadow: false)
    }

    private var actions: some View {
        HStack(spacing: 4) {
            if let fileURL {
                Button { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) } label: { Image(systemName: "folder") }
                    .buttonStyle(IconButtonStyle(size: 30, tint: Theme.bone))
                    .help("Im Finder zeigen")
                Button { NSWorkspace.shared.open(fileURL) } label: { Image(systemName: "arrow.up.forward.app") }
                    .buttonStyle(IconButtonStyle(size: 30, tint: Theme.bone))
                    .help("Öffnen")
            }
            if kind == .image, let fileURL, let data = try? Data(contentsOf: fileURL) {
                Button {
                    NSPasteboard.general.clearContents()
                    if let image = NSImage(data: data) { NSPasteboard.general.writeObjects([image]) }
                } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(IconButtonStyle(size: 30, tint: Theme.bone))
                    .help("Bild kopieren")
                Button {
                    if let attachment = AttachmentFactory.image(data: data, filename: fileURL.lastPathComponent) {
                        withAnimation(Theme.Motion.bouncy) { store.addAttachments([attachment]) }
                    }
                } label: { Image(systemName: "paperclip") }
                    .buttonStyle(IconButtonStyle(size: 30, tint: Theme.bone))
                    .help("Als Anhang verwenden – z. B. für /video oder zum Weiterbearbeiten mit /foto")
            }
        }
        .padding(4)
        .background(Capsule().fill(.ultraThinMaterial))
    }
}

/// Stummes, endlos laufendes Video ohne Bedienleiste; Klick pausiert.
struct LoopingVideo: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer(playerItem: item)
        context.coordinator.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = false
        player.play()
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var looper: AVPlayerLooper?
    }
}

/// Laufende Erzeugung – Platzhalter im Chat mit Fortschritt.
struct MediaJobView: View {
    let job: MediaStudio.Job
    @Environment(AppStore.self) private var store

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.void.opacity(0.5))
                    if job.error == nil {
                        EmberMark(size: 34, intensity: 0.9)
                    } else {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.clay)
                    }
                }
                .frame(width: 64, height: job.kind == .video ? 40 : 64)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(job.kind.command).font(Theme.Fonts.mono(11.5, .medium)).foregroundStyle(Theme.ochre)
                        Text(job.prompt).font(Theme.Fonts.sans(12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    }
                    if let error = job.error {
                        Text(error)
                            .font(Theme.Fonts.sans(11))
                            .foregroundStyle(Theme.clay)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        let seconds = Int(context.date.timeIntervalSince(job.started))
                        ShimmerText(text: "\(job.status) · \(seconds) s", font: Theme.Fonts.sans(11))
                    }
                }
                Spacer()
                if job.error != nil {
                    Button { store.media.dismiss(job) } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 24))
                }
            }
            .padding(12)
            .glass(cornerRadius: 16, tint: job.error == nil ? Theme.ember : Theme.clay, tintOpacity: 0.2, shadow: false)
        }
    }
}
