import SwiftUI

// MARK: Frosted Glass

struct GlassPanel: ViewModifier {
    var cornerRadius: CGFloat = 20
    var tint: Color = Theme.raise
    var tintOpacity: Double = 0.45
    var shadow = true

    func body(content: Content) -> some View {
        content
            .background {
                let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                shape
                    .fill(Theme.raise)
                    // Farbiger Schimmer nur, wenn ausdrücklich eine Akzentfarbe übergeben wird
                    .overlay(shape.fill(tint.opacity(tintOpacity * 0.25)))
                    .overlay(shape.strokeBorder(Theme.line, lineWidth: 1))
            }
    }
}

extension View {
    func glass(cornerRadius: CGFloat = 20, tint: Color = Theme.forest, tintOpacity: Double = 0.45, shadow: Bool = true) -> some View {
        modifier(GlassPanel(cornerRadius: cornerRadius, tint: tint, tintOpacity: tintOpacity, shadow: shadow))
    }
}

// MARK: Buttons

/// Glas-Kapsel mit Hover-Aufhellung und federndem Druck.
struct PillButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Theme.ochre

    func makeBody(configuration: Configuration) -> some View {
        PillBody(configuration: configuration, prominent: prominent, tint: tint)
    }

    private struct PillBody: View {
        let configuration: Configuration
        let prominent: Bool
        let tint: Color
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.Fonts.sans(12, .medium))
                .foregroundStyle(prominent ? Theme.void : Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(tint.opacity(hovering ? 1 : 0.9)) : AnyShapeStyle(.white.opacity(hovering ? 0.1 : 0.05)))
                        .overlay(Capsule().strokeBorder(.white.opacity(prominent ? 0 : 0.09)))
                }
                .scaleEffect(configuration.isPressed ? 0.95 : (hovering ? 1.02 : 1))
                .opacity(isEnabled ? 1 : 0.4)
                .animation(Theme.Motion.snappy, value: configuration.isPressed)
                .animation(Theme.Motion.snappy, value: hovering)
                .onHover { hovering = $0 }
        }
    }
}

/// Runder Icon-Knopf.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var tint: Color = Theme.textSecondary
    var filled: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        IconBody(configuration: configuration, size: size, tint: tint, filled: filled)
    }

    private struct IconBody: View {
        let configuration: Configuration
        let size: CGFloat
        let tint: Color
        let filled: Color?
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: size * 0.42, weight: .medium))
                .foregroundStyle(filled != nil ? Theme.void : (hovering ? Theme.textPrimary : tint))
                .frame(width: size, height: size)
                .background {
                    Circle().fill(filled.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.white.opacity(hovering ? 0.08 : 0)))
                }
                .scaleEffect(configuration.isPressed ? 0.88 : (hovering ? 1.06 : 1))
                .opacity(isEnabled ? 1 : 0.35)
                .animation(Theme.Motion.bouncy, value: configuration.isPressed)
                .animation(Theme.Motion.snappy, value: hovering)
                .onHover { hovering = $0 }
                .contentShape(Circle())
        }
    }
}

/// Zeile mit Hover-Fläche (Sidebar).
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.045 : 0))
                }
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(Theme.Motion.snappy, value: hovering)
                .animation(Theme.Motion.snappy, value: configuration.isPressed)
                .onHover { hovering = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// App-Icon eines Projekts in der typischen abgerundeten Form – oder ein ruhiger Platzhalter mit Anfangsbuchstaben.
struct AppIconView: View {
    let info: ProjectInfo
    var size: CGFloat = 28

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let icon = info.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Text(String(info.appName.prefix(1)).uppercased())
                    .font(.system(size: size * 0.45, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.lift)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 0.5))
    }
}
