import Foundation

/// Zielplattform des aktuellen Projekts. Wird jedem Prompt als System-Hinweis mitgegeben –
/// unabhängig davon, welches Modell gerade arbeitet.
enum TargetPlatform: String, CaseIterable, Identifiable, Codable, Sendable {
    case iOS, iPadOS, macOS, multiplatform

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iOS: "iPhone"
        case .iPadOS: "iPad"
        case .macOS: "Mac"
        case .multiplatform: "Multiplatform"
        }
    }

    var symbol: String {
        switch self {
        case .iOS: "iphone"
        case .iPadOS: "ipad"
        case .macOS: "macbook"
        case .multiplatform: "apps.iphone"
        }
    }

    var systemHint: String {
        switch self {
        case .iOS:
            """
            Zielplattform: iOS (iPhone). Baue und teste für einen iPhone-Simulator. \
            Halte dich an die iOS-HIG: NavigationStack, TabView, Safe Areas, Dynamic Type, Touch-Ziele ≥ 44 pt. \
            Lade bei Bedarf den Skill `apple-platform-ios`.
            """
        case .iPadOS:
            """
            Zielplattform: iPadOS. Baue und teste für einen iPad-Simulator. \
            Nutze NavigationSplitView, unterstütze alle Größenklassen, Multitasking/Stage Manager, Tastatur- und Pointer-Eingabe. \
            Lade bei Bedarf den Skill `apple-platform-ipados`.
            """
        case .macOS:
            """
            Zielplattform: macOS. Baue für „platform=macOS“ und starte die App lokal. \
            Nutze Fenster-, Menü- und Toolbar-Konventionen des Mac (Commands, Settings-Szene, Tastenkürzel). \
            Lade bei Bedarf den Skill `apple-platform-macos`.
            """
        case .multiplatform:
            """
            Zielplattform: iOS, iPadOS und macOS aus einer Codebasis. \
            Teile Logik und Views, trenne Plattformunterschiede mit `#if os(...)` bzw. Size Classes und baue alle Ziele. \
            Lade bei Bedarf die Skills `apple-platform-ios`, `apple-platform-ipados` und `apple-platform-macos`.
            """
        }
    }
}
