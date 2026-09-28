import SwiftUI

/// The segmented switch at the top of the expanded panel.
///
/// Collapsed, media and agents are both on screen at once on opposite shoulders. Expanded,
/// there is only room to elaborate one of them properly — a split panel would give each half
/// less than the collapsed shoulders already have. So the user picks, explicitly, and the
/// choice persists until they change it or an approval takes over.
///
/// This is the only chrome in the app the user operates directly, which is why it gets a real
/// hit target and a visible track rather than two bare words.
///
/// **It is deliberately not centred.** Horizontally centred at the top of the panel puts it
/// directly beneath the physical camera housing — the one strip of the panel the user cannot
/// see — so the app's only operable control was invisible. It now hugs its content at the
/// leading edge (`fixedSize`, plus the header `VStack`'s `alignment: .leading`) and rides the
/// smaller `Metrics.TabBar` tokens with `Text.micro` type, so it clears the housing and reads
/// as chrome rather than as the largest thing in the header. Do not "fix" the alignment back.
@MainActor
struct NotchTabBar: View {
    @Binding var selection: NotchSurface
    /// Tabs with nothing behind them are still shown, not hidden. A switch whose options
    /// appear and disappear as tracks start and agents exit is a moving target; a dimmed tab
    /// that says "nothing here" is honest and stays put.
    let activeSurfaces: Set<NotchSurface>

    var body: some View {
        HStack(spacing: Theme.Metrics.TabBar.spacing) {
            ForEach(NotchSurface.allCases) { surface in
                tab(surface)
            }
        }
        .padding(Theme.Metrics.TabBar.spacing)
        .background(
            RoundedRectangle(
                cornerRadius: Theme.Metrics.TabBar.cornerRadius
                    + Theme.Metrics.TabBar.spacing,
                style: .continuous
            )
            .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.TabBar.trackFillOpacity))
        )
        // The track is drawn on the `HStack` itself, so anything that stretches the stack
        // stretches the pill track with it into a bar across the whole panel. `fixedSize`
        // pins it to its ideal width and lets the parent's leading alignment do the placing.
        .fixedSize()
    }

    private func tab(_ surface: NotchSurface) -> some View {
        Button {
            guard selection != surface else { return }
            withAnimation(Theme.Motion.content) {
                selection = surface
            }
        } label: {
            Text(surface.title)
                // `micro`, not `caption`: at the reduced 20pt track height caption crowds the
                // pill to its edges and the switch stops reading as chrome.
                .font(Theme.Text.micro)
                .foregroundStyle(
                    selection == surface
                        ? Theme.Colors.textPrimary
                        : activeSurfaces.contains(surface)
                            ? Theme.Colors.textSecondary
                            : Theme.Colors.textTertiary
                )
                .padding(.horizontal, Theme.Metrics.TabBar.horizontalPadding)
                .frame(height: Theme.Metrics.TabBar.height)
                .background(selectionBackground(for: surface))
                // Applied *after* the frame so the hit area is the whole drawn pill, not just
                // the glyphs. Shrinking the type would otherwise shrink the click target with
                // it; the shape keeps the target at the pill's size whatever the font does.
                .contentShape(
                    RoundedRectangle(
                        cornerRadius: Theme.Metrics.TabBar.cornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(surface.title)
        .accessibilityAddTraits(selection == surface ? [.isSelected] : [])
    }

    /// One shared `matchedGeometryEffect` so the selected pill *slides* between tabs instead of
    /// cross-fading. With two tabs a fade reads as both being half-selected for the duration.
    @ViewBuilder
    private func selectionBackground(for surface: NotchSurface) -> some View {
        if selection == surface {
            RoundedRectangle(
                cornerRadius: Theme.Metrics.TabBar.cornerRadius,
                style: .continuous
            )
            .fill(Theme.Colors.textPrimary.opacity(Theme.Metrics.TabBar.selectedFillOpacity))
            .matchedGeometryEffect(id: "tab", in: namespace)
        }
    }

    @Namespace private var namespace
}
