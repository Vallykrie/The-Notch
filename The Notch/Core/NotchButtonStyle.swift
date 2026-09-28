import SwiftUI

/// The notch's own button. AppKit's bordered styles paint a system-tinted control that reads
/// as a dialog dropped into the panel; this is a quiet translucent capsule that belongs to the
/// black silhouette. Every value comes from `Theme.Metrics.Control`.
struct NotchButtonStyle: ButtonStyle {
    var verticalPadding: CGFloat = Theme.Metrics.Control.verticalPadding

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Text.body)
            .foregroundStyle(.white)
            .padding(.horizontal, Theme.Metrics.Control.horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                RoundedRectangle(
                    cornerRadius: Theme.Metrics.Control.cornerRadius,
                    style: .continuous
                )
                .fill(.white.opacity(
                    configuration.isPressed
                        ? Theme.Metrics.Control.pressedFillOpacity
                        : Theme.Metrics.Control.fillOpacity
                ))
            )
            .overlay(
                RoundedRectangle(
                    cornerRadius: Theme.Metrics.Control.cornerRadius,
                    style: .continuous
                )
                .strokeBorder(
                    .white.opacity(Theme.Metrics.Control.borderOpacity),
                    lineWidth: Theme.Metrics.Control.borderWidth
                )
            )
            .contentShape(Rectangle())
            .animation(Theme.Motion.content, value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == NotchButtonStyle {
    static var notch: NotchButtonStyle { NotchButtonStyle() }

    /// The same control, shorter. For the stack of answers on the question card, where the
    /// height of a row is the difference between four answers fitting and three — see
    /// `ApprovalCardView`. Only the vertical padding changes, so a compact row still reads as
    /// the same kind of thing as the buttons beside it.
    static var notchCompact: NotchButtonStyle {
        NotchButtonStyle(verticalPadding: Theme.Metrics.Control.compactVerticalPadding)
    }
}
