import SwiftUI
import AppKit

// One dark palette. Old appearance preferences are deliberately ignored.
enum Palette {
    static let nativeBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    static let surface = Color(nsColor: nativeBlack)
    static let text = Color(white: 0.91)
    static let secondary = Color(white: 0.62)
    static let tertiary = Color(white: 0.42)
    static let hover = Color(white: 0.11)
    static let selection = Color(white: 0.16)
    static let track = Color(white: 0.22)
    static let hairline = Color.white.opacity(0.08)
    static let onText = Color.black
    static let separator = Color(nsColor: NSColor(name: nil) { appearance in
        let highContrast = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .darkAqua]) == .accessibilityHighContrastDarkAqua
        return NSColor(white: highContrast ? 0.45 : 0.16, alpha: 1)
    })
}

// One horizontal gutter for every notch page, so all leading edges line up.
enum Metrics {
    static let gutter: CGFloat = 20
    /// Rows carry their own inset so hover fills reach past the text.
    static let rowInset: CGFloat = 10
    static let rowShape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    static let captionSpacing: CGFloat = 14
}

/// Subtle scale on press: the interface acknowledges the click immediately.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.94
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// List rows: hover fill without animation (seen tens of times a minute),
/// a brighter fill while pressed. Pass `selected` when keyboard selection
/// owns the highlight; otherwise the row tracks hover itself.
struct RowStyle: ButtonStyle {
    var selected: Bool? = nil
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selected: selected)
    }
    private struct RowBody: View {
        let configuration: Configuration
        let selected: Bool?
        @State private var hovering = false
        var body: some View {
            let highlighted = selected ?? hovering
            configuration.label
                .environment(\.rowHighlighted, highlighted)
                .padding(Metrics.rowInset)
                .background(configuration.isPressed ? Palette.selection : highlighted ? Palette.hover : .clear, in: Metrics.rowShape)
                .contentShape(Metrics.rowShape)
                .onHover { if selected == nil { hovering = $0 } }
        }
    }
}

private struct RowHighlightedKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Set by RowStyle so row content can reveal hover-only affordances.
    var rowHighlighted: Bool {
        get { self[RowHighlightedKey.self] }
        set { self[RowHighlightedKey.self] = newValue }
    }
}
