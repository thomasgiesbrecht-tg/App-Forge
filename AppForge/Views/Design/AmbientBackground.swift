import SwiftUI

/// Hintergrund: reines Schwarz. Die einzige Bewegung ist die Aura hinter dem Eingabefeld (siehe `ComposerAura`).
struct AmbientBackground: View {
    var isWorking: Bool

    var body: some View {
        Theme.black.ignoresSafeArea()
    }
}

/// Weiches Leuchten hinter dem Eingabefeld: orange, solange die KI arbeitet,
/// kurz grün, wenn sie fertig ist, sonst gar nicht vorhanden (der Weichzeichner ist teuer).
struct ComposerAura: View {
    var isWorking: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var mounted = false
    @State private var working = false
    @State private var glow: Double = 0
    @State private var breathe = false

    var body: some View {
        ZStack {
            if mounted {
                Ellipse()
                    .fill(RadialGradient(colors: [working ? Theme.orange : Theme.green, .clear],
                                         center: .center, startRadius: 0, endRadius: 260))
                    .frame(height: 90)
                    .padding(.horizontal, 60)
                    .blur(radius: 34)
                    .opacity(glow * (breathe ? 0.6 : 1))
                    .scaleEffect(x: breathe ? 0.92 : 1, y: 1)
                    .offset(y: 26)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: isWorking, initial: true) { wasWorking, nowWorking in
            working = nowWorking
            if nowWorking {
                mounted = true
                withAnimation(.easeInOut(duration: 1.2)) { glow = 0.5 }
                if !reduceMotion {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathe = true }
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { breathe = false }
                guard wasWorking, mounted else { mounted = false; return }
                // Fertig: kurz grün aufleuchten, dann ausblenden und entfernen.
                glow = 0.35
                withAnimation(.easeOut(duration: 2.4)) { glow = 0 }
                Task {
                    try? await Task.sleep(for: .seconds(2.5))
                    if !working { mounted = false }
                }
            }
        }
    }
}
