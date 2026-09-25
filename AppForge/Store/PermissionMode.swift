import Foundation

/// Wie viel die KI ohne Rückfrage tun darf. Die Engine fragt immer – AppForge beantwortet
/// je nach Modus automatisch oder zeigt die Freigabe-Leiste.
enum PermissionMode: String, CaseIterable, Identifiable, Sendable {
    case ask, auto, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: "Fragen"
        case .auto: "Automatisch"
        case .full: "Alles erlauben"
        }
    }

    var symbol: String {
        switch self {
        case .ask: "hand.raised"
        case .auto: "wand.and.stars"
        case .full: "bolt"
        }
    }

    var detail: String {
        switch self {
        case .ask: "Jede Dateiänderung und jeder Befehl braucht deine Freigabe."
        case .auto: "Änderungen und normale Befehle laufen durch. Riskantes (löschen, pushen, sudo …) und Zugriffe außerhalb des Projekts fragen nach."
        case .full: "Alles läuft ohne Rückfrage. Nur verwenden, wenn du dem Modell vertraust."
        }
    }

    func autoApproves(_ request: PermissionRequest) -> Bool {
        switch self {
        case .ask:
            return false
        case .full:
            return true
        case .auto:
            switch request.permission {
            case "edit", "write", "read", "glob", "grep", "list", "todowrite", "todoread",
                 "skill", "webfetch", "websearch", "codesearch", "task", "lsp":
                return true
            case "bash":
                return !request.patterns.contains(where: Self.isRisky)
            default:
                // z. B. external_directory, doom_loop – lieber nachfragen
                return false
            }
        }
    }

    private static let riskyPatterns: [String] = [
        #"\brm\s+-[a-zA-Z]*[rRf]"#, #"\bsudo\b"#, #"\bgit\s+(push|reset\s+--hard|clean|rebase|branch\s+-D|checkout\s+--)"#,
        #"curl[^|]*\|\s*(ba|z)?sh"#, #"\bchmod\s+-R"#, #"\bkillall\b"#, #"simctl\s+(erase|delete)"#,
        #"\b(altool|notarytool|fastlane)\b"#, #"\bdd\s+if="#, #">\s*/dev/"#, #"\bmkfs"#, #"defaults\s+delete"#,
        #"\bbrew\s+(uninstall|remove)"#, #"\bnpm\s+publish"#, #"\bdiskutil\b"#, #"\blaunchctl\b"#,
        // DaVinci Resolve: von den DaVinci-Agenten gesetzter Marker und zerstörerische API-Aufrufe
        #"\bDAVINCI_FREIGABE=1\b"#,
        #"\b(Delete(Timelines|Clips|Folders|VersionByName|Stills|ColorGroup|FusionCompByName|GalleryStillAlbum|Project|RenderJob|AllRenderJobs)|ResetAllGrades|StartRendering|CloseProject)\b"#,
    ]

    static func isRisky(_ command: String) -> Bool {
        riskyPatterns.contains { command.range(of: $0, options: .regularExpression) != nil }
    }
}
