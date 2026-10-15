import SwiftUI

/// The gear at the trailing edge of the expanded panel's header.
///
/// It only exists while the panel is open, which is to say while the pointer is on the notch —
/// so the app's configuration is exactly one hover and one click away, and nothing is parked in
/// the menu bar or the Dock to find it through. (There is no Dock icon: the app is
/// `LSUIElement`.)
///
/// Trailing, not leading, because the tab bar already owns the leading edge, and not centred
/// because the centre of the header is behind the physical camera housing — the one strip of the
/// panel the user cannot see. `NotchTabBar` has the same constraint and the same comment.
@MainActor
struct NotchGearButton: View {
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PixelGlyphView(
                glyph: .gear,
                side: Theme.Metrics.Settings.gearGlyphSize
            )
            .foregroundStyle(
                isActive ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
            )
            .frame(
                width: Theme.Metrics.Settings.gearHitSize,
                height: Theme.Metrics.Settings.gearHitSize
            )
            .background(
                RoundedRectangle(
                    cornerRadius: Theme.Metrics.TabBar.cornerRadius,
                    style: .continuous
                )
                .fill(
                    Theme.Colors.textPrimary.opacity(
                        isActive ? Theme.Metrics.Settings.gearActiveFillOpacity : 0
                    )
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// A button for the header row: Restore defaults, Updates, Quit, Clear idle.
///
/// `NotchButtonStyle` at `.compact`, the size of the tab pills it replaces or sits beside, so
/// the header row reads as one strip of chrome whichever surface is showing.
@MainActor
struct NotchHeaderActionButton: View {
    let title: String
    var role: NotchButtonStyle.Role = .secondary
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(NotchButtonStyle(role: role, size: .compact))
            .disabled(!isEnabled)
            .accessibilityLabel(title)
    }
}
