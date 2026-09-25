import SwiftUI

/// Rotierender Glut-Bogen – der Lade-Indikator der App.
struct ForgeSpinner: View {
    var size: CGFloat = 14
    var lineWidth: CGFloat = 1.8
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(
                AngularGradient(colors: [Theme.orange.opacity(0), Theme.orange], center: .center),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}

/// Häkchen, das sich selbst zeichnet.
struct DrawnCheckmark: View {
    var size: CGFloat = 12
    var color: Color = Theme.sage
    @State private var progress: CGFloat = 0

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: size * 0.15, y: size * 0.52))
            path.addLine(to: CGPoint(x: size * 0.42, y: size * 0.78))
            path.addLine(to: CGPoint(x: size * 0.86, y: size * 0.24))
        }
        .trim(from: 0, to: progress)
        .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        .frame(width: size, height: size)
        .onAppear { withAnimation(.easeOut(duration: 0.45).delay(0.05)) { progress = 1 } }
    }
}

/// Drei atmende Punkte.
struct BreathingDots: View {
    var color: Color = Theme.ochre

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    let phase = sin(t * 3.2 - Double(index) * 0.7)
                    Circle()
                        .fill(color)
                        .frame(width: 5, height: 5)
                        .scaleEffect(0.7 + 0.35 * (phase + 1) / 2)
                        .opacity(0.35 + 0.65 * (phase + 1) / 2)
                }
            }
        }
    }
}

/// Text mit wanderndem Lichtschimmer.
struct ShimmerText: View {
    let text: String
    var font: Font = Theme.Fonts.small

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let x = (t.truncatingRemainder(dividingBy: 2.2)) / 2.2 * 1.6 - 0.3
            Text(text)
                .font(font)
                .foregroundStyle(Theme.textTertiary)
                .overlay {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: max(0, x - 0.15)),
                            .init(color: Theme.sand, location: min(1, max(0, x))),
                            .init(color: .clear, location: min(1, x + 0.15)),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .mask(Text(text).font(font))
                }
        }
    }
}

/// Das Zeichen von AppForge: ein ruhiger Lichtpunkt, der sanft atmet.
struct EmberMark: View {
    var size: CGFloat = 64
    var intensity: Double = 1

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Theme.textPrimary.opacity(0.18 * intensity), .clear],
                                         center: .center, startRadius: 0, endRadius: size * 0.55))
                    .scaleEffect(1 + 0.06 * sin(t * 1.2))
                Circle()
                    .strokeBorder(Theme.line, lineWidth: 1)
                    .frame(width: size * 0.62, height: size * 0.62)
                Circle()
                    .fill(Theme.textPrimary)
                    .frame(width: size * 0.12, height: size * 0.12)
                    .opacity(0.75 + 0.25 * sin(t * 1.6))
            }
            .frame(width: size, height: size)
        }
    }
}

/// Weiches Einblenden von unten – für neue Nachrichten.
/// Bewusst ohne Unschärfe: Der Modifier bleibt dauerhaft an jeder Zeile hängen,
/// und ein Filter (auch mit Stärke 0) macht das Scrollen spürbar langsamer.
struct RiseIn: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .opacity(active ? 0 : 1)
            .offset(y: active ? 14 : 0)
    }
}

extension View {
    /// Abdunkeln und entsättigen – nur wenn nötig, damit normale Zeilen keinen Filter tragen.
    @ViewBuilder func dimmed(_ on: Bool) -> some View {
        if on { self.opacity(0.28).saturation(0) } else { self }
    }
}

extension AnyTransition {
    static var riseIn: AnyTransition {
        .modifier(active: RiseIn(active: true), identity: RiseIn(active: false))
    }
}

/// Weiches Ausblenden am oberen und unteren Rand einer Scrollfläche.
/// Als schwarze Verläufe darübergelegt statt als Maske – eine Maske zwingt macOS,
/// die gesamte Scrollfläche bei jedem Bild in ein Zwischenbild zu rendern.
struct EdgeFade: View {
    var height: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.black, Theme.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
            Spacer(minLength: 0)
            LinearGradient(colors: [Theme.black.opacity(0), Theme.black], startPoint: .top, endPoint: .bottom)
                .frame(height: height)
        }
        .allowsHitTesting(false)
    }
}
