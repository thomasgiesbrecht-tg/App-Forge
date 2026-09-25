import CoreText
import SwiftUI

/// „Aura dunkel“ – reines Schwarz und Graustufen. Arbeit wird weiß angezeigt, Grün heißt fertig,
/// Rot heißt Fehler oder Problem. Orange nur noch, wenn du selbst etwas tun musst.
enum Theme {
    // MARK: Palette

    static let black = Color(hex: 0x000000)
    static let raise = Color(hex: 0x0B0B0B)      // Flächen
    static let lift = Color(hex: 0x141414)       // Hover, Eingaben, eigene Nachrichten
    static let line = Color(hex: 0x1E1E1E)       // Linien
    /// Nur für „braucht dich“ (Freigaben, fehlende Einstellung).
    static let orange = Color(hex: 0xFF8A33)
    static let green = Color(hex: 0x4CD97B)
    static let red = Color(hex: 0xF2555A)
    /// Arbeitet gerade · Hauptaktion – bewusst neutral statt farbig.
    static let active = Color(hex: 0xE6E6E1)

    static let textPrimary = Color(hex: 0xF2F2F0)
    static let textSecondary = Color(hex: 0x8C8C8C)
    static let textTertiary = Color(hex: 0x555555)
    static let accent = green
    static let attention = orange
    static let danger = red
    static let success = green
    static let hairline = line

    // Ältere Namen, auf die neue Palette abgebildet
    static let void = black
    static let night = black
    static let forest = raise
    static let pine = lift
    static let moss = Color(hex: 0x2A2A2A)
    static let sage = green
    static let bark = raise
    static let ember = lift
    static let clay = red
    static let ochre = active
    static let sand = Color(hex: 0xD9D9D6)
    static let bone = textPrimary
    static let ash = textSecondary
    static let smoke = textTertiary

    // MARK: Typografie

    enum Fonts {
        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            FontRegistry.hasGeist ? .custom("Geist", size: size).weight(weight) : .system(size: size, weight: weight)
        }

        static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            FontRegistry.hasGeistMono ? .custom("Geist Mono", size: size).weight(weight) : .system(size: size, weight: weight, design: .monospaced)
        }

        static let body = sans(13.5)
        static let small = sans(11.5)
        static let title = sans(15, .medium)
        static let display = sans(30, .light)
    }

    // MARK: Bewegung

    enum Motion {
        static let spring = Animation.spring(response: 0.5, dampingFraction: 0.82)
        static let snappy = Animation.spring(response: 0.32, dampingFraction: 0.78)
        static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.62)
        static let gentle = Animation.easeInOut(duration: 0.7)
    }
}

/// Kleine, ruhige Abschnittsbeschriftung.
struct Eyebrow: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.sans(11.5))
            .foregroundStyle(Theme.textTertiary)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

/// Registriert mitgelieferte Schriften (Geist / Geist Mono), falls im Bundle vorhanden.
/// Fehlen sie, fällt das Design auf die Systemschrift zurück.
enum FontRegistry {
    private static let families: Set<String> = {
        let urls = (Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? [])
            + (Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? [])
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return Set(names)
    }()

    static var hasGeist: Bool { families.contains("Geist") }
    static var hasGeistMono: Bool { families.contains("Geist Mono") }
}
