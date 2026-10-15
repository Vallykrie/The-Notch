import SwiftUI

/// The notch's one button. AppKit's bordered styles paint a system-tinted control that reads
/// as a dialog dropped into the panel; this belongs to the black silhouette. Every value comes
/// from `Theme.Metrics.Control`.
///
/// It is a grid, and every button in the app picks a cell of it. There used to be seven
/// separately drawn buttons across ten call sites — three corner radii, heights from 14 to
/// 22pt, outlined and filled versions of the same job — and "Dismiss" rendered larger and
/// heavier than the "Answer" it sat beside, because a `.font` applied outside a style loses to
/// the one the style sets inside.
///
/// - `Role` says how much the button matters: the one action that resolves the surface is
///   `.primary`, every other button is `.secondary`, and a link-like action that should not
///   compete with either is `.tertiary`.
/// - `Size` says where it sits: `.regular` stands on its own, `.compact` sits in the header row
///   beside the tab pills it matches, `.inline` sits inside a list row.
struct NotchButtonStyle: ButtonStyle {
    enum Role {
        /// Filled with `tint`, label in the surface colour.
        case primary(tint: Color)
        /// A translucent plate with a hairline edge.
        case secondary
        /// Text only, with a plate on hover and press.
        case tertiary
    }

    enum Size {
        case regular
        case compact
        case inline

        var height: CGFloat {
            switch self {
            case .regular: Theme.Metrics.Control.regularHeight
            case .compact: Theme.Metrics.Control.compactHeight
            case .inline: Theme.Metrics.Control.inlineHeight
            }
        }

        var font: Font {
            switch self {
            case .regular: Theme.Text.caption
            case .compact, .inline: Theme.Text.micro
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: Theme.Metrics.Control.horizontalPadding
            case .compact: Theme.Metrics.Control.compactHorizontalPadding
            case .inline: Theme.Metrics.Control.inlineHorizontalPadding
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .regular: Theme.Metrics.Control.cornerRadius
            case .compact, .inline: Theme.Metrics.Control.smallCornerRadius
            }
        }
    }

    var role: Role = .secondary
    var size: Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        Rendered(configuration: configuration, role: role, size: size)
    }

    /// A view, not inline in `makeBody`, because the disabled look reads the environment and
    /// the tertiary hover needs state.
    private struct Rendered: View {
        let configuration: Configuration
        let role: Role
        let size: Size

        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            configuration.label
                .font(size.font)
                .foregroundStyle(foreground)
                .lineLimit(1)
                .padding(.horizontal, size.horizontalPadding)
                .frame(height: size.height)
                .background(shape.fill(fill))
                .overlay {
                    if case .secondary = role {
                        shape.strokeBorder(
                            Theme.Colors.textPrimary.opacity(Theme.Metrics.Control.borderOpacity),
                            lineWidth: Theme.Metrics.Control.borderWidth
                        )
                    }
                }
                .opacity(isEnabled ? 1 : Theme.Metrics.Control.disabledOpacity)
                .contentShape(shape)
                .onHover { isHovered = $0 }
                .animation(Theme.Motion.content, value: configuration.isPressed)
                .animation(Theme.Motion.content, value: isHovered)
        }

        private var foreground: Color {
            switch role {
            case .primary: Theme.Colors.surface
            case .secondary: Theme.Colors.textPrimary
            case .tertiary: isHovered ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
            }
        }

        private var fill: Color {
            let pressed = configuration.isPressed && isEnabled
            switch role {
            case .primary(let tint):
                return tint.opacity(pressed ? Theme.Metrics.Control.primaryPressedOpacity : 1)
            case .secondary:
                return Theme.Colors.textPrimary.opacity(
                    pressed ? Theme.Metrics.Control.pressedFillOpacity : Theme.Metrics.Control.fillOpacity
                )
            case .tertiary:
                let opacity = pressed
                    ? Theme.Metrics.Control.fillOpacity
                    : (isHovered && isEnabled ? Theme.Metrics.Control.hoverFillOpacity : 0)
                return Theme.Colors.textPrimary.opacity(opacity)
            }
        }
    }
}

extension ButtonStyle where Self == NotchButtonStyle {
    /// The one action that resolves the surface.
    static func notchPrimary(tint: Color, size: NotchButtonStyle.Size = .regular) -> NotchButtonStyle {
        NotchButtonStyle(role: .primary(tint: tint), size: size)
    }

    static func notchSecondary(size: NotchButtonStyle.Size = .regular) -> NotchButtonStyle {
        NotchButtonStyle(role: .secondary, size: size)
    }

    static func notchTertiary(size: NotchButtonStyle.Size = .regular) -> NotchButtonStyle {
        NotchButtonStyle(role: .tertiary, size: size)
    }

    static var notch: NotchButtonStyle { .notchSecondary() }
}
