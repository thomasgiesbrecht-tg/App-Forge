import SwiftUI
import UIKit

/// „Aura dunkel“ wie in AppForge am Mac: Schwarz, Graustufen, Orange (arbeitet · deine Aktion), Grün (fertig).
enum Palette {
    static let black = Color(red: 0, green: 0, blue: 0)
    static let raise = Color(red: 11 / 255, green: 11 / 255, blue: 11 / 255)
    static let lift = Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255)
    static let line = Color(red: 30 / 255, green: 30 / 255, blue: 30 / 255)
    static let orange = Color(red: 1, green: 138 / 255, blue: 51 / 255)
    static let green = Color(red: 76 / 255, green: 217 / 255, blue: 123 / 255)
    static let text = Color(red: 242 / 255, green: 242 / 255, blue: 240 / 255)
    static let secondary = Color(red: 140 / 255, green: 140 / 255, blue: 140 / 255)
    static let tertiary = Color(red: 85 / 255, green: 85 / 255, blue: 85 / 255)

    static func color(for kind: LiveTaskState.Kind) -> Color {
        switch kind {
        case .running: orange
        case .needsYou: orange
        case .done: green
        case .failed: orange
        }
    }
}

/// App-Icon in der typischen Form – oder ein Platzhalter (Anfangsbuchstabe bzw. Mac-Symbol).
struct ProjectIconView: View {
    var name: String
    var icon: Data?
    var isMac = false
    var size: CGFloat = 44

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let icon, let image = UIImage(data: icon) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if isMac {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.lift)
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.lift)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

extension ProjectIconView {
    init(_ project: CompanionProject, size: CGFloat = 44) {
        self.init(name: project.name, icon: project.iconPNG, isMac: project.isMac, size: size)
    }
}
