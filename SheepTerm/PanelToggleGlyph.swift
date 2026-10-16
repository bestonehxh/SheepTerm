import SwiftUI

/// The tab bar's sidebar / AI panel buttons (5.0 (27), the user's drawing):
/// a rounded window outline; closed = a short bar inside on that side,
/// open = a full-height divider. Mirrored for the right-hand AI panel.
/// Colour comes from the button (the AI one is accent while open).
struct PanelToggleGlyph: View {
    let trailing: Bool
    let open: Bool

    var body: some View {
        Canvas { context, size in
            let line: CGFloat = 1.3
            let box = CGRect(origin: .zero, size: size).insetBy(dx: line / 2, dy: line / 2)
            context.stroke(Path(roundedRect: box, cornerRadius: 3.2), with: .foreground, lineWidth: line)
            let mark: CGRect
            if open {
                let x = box.width * 0.36
                mark = CGRect(x: trailing ? box.maxX - x - line / 2 : box.minX + x - line / 2,
                              y: box.minY, width: line, height: box.height)
            } else {
                let x = box.width * 0.2
                let h = box.height * 0.5
                mark = CGRect(x: trailing ? box.maxX - x - line / 2 : box.minX + x - line / 2,
                              y: box.midY - h / 2, width: line, height: h)
            }
            context.fill(Path(roundedRect: mark, cornerRadius: line / 2), with: .foreground)
        }
        .frame(width: 16, height: 13)
        .accessibilityHidden(true)   // the button carries the name
    }
}

/// Every icon button in the tab bar (sidebar, search, +, AI panel): grey,
/// brighter on a soft rounded box under the pointer, brighter still (white) while
/// pressed (the user's sketch) — the same for all of them. `tint` fixes the
/// icon's colour (the AI button while its panel is open).
/// One box size for every icon (26 × 24) so the gaps between buttons read
/// even; `width: nil` = a labelled button (Sign In), as wide as its content.
struct ChromeIconBox: ViewModifier {
    var tint: Color? = nil
    var pressed = false
    var width: CGFloat? = 26
    var height: CGFloat = 24
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(tint ?? (pressed ? Color.white : (hovering ? Theme.tabText : Theme.dimText)))
            .padding(.horizontal, width == nil ? 6 : 0)
            .frame(width: width, height: height)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(pressed ? 0.2 : (hovering ? 0.08 : 0))))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct ChromeIconButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var width: CGFloat? = 26
    var height: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(ChromeIconBox(tint: tint, pressed: configuration.isPressed, width: width, height: height))
    }
}
