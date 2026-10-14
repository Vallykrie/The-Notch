import SwiftUI

/// Every calendar on the Mac, from every account, each one switchable on its own.
///
/// Reached from Settings › Calendar › Calendars…, the same way agent connections are. A work
/// Exchange calendar and a personal iCloud one can sit side by side in the agenda, and the
/// holidays calendar nobody asked for can go.
@MainActor
struct CalendarSourcesView: View {
    @ObservedObject var store: CalendarStore
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("‹ Settings", action: onBack)
                Spacer()
                Button("Add account…") { CalendarStore.openInternetAccounts() }
                    .help("Google, Microsoft Exchange / Outlook and CalDAV accounts are added in System Settings › Internet Accounts.")
                Button("Refresh") { store.refresh() }
            }
            .buttonStyle(.plain)
            .font(Theme.Text.caption)

            if store.calendars.isEmpty {
                Text("No calendars yet. Add an account in Internet Accounts and turn on Calendars for it.")
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
            } else {
                ViewThatFits(in: .vertical) {
                    grid
                    ScrollView { grid }.scrollIndicators(.hidden)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var grid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible())],
            alignment: .leading,
            spacing: 2
        ) {
            ForEach(store.calendars) { source in
                row(source)
            }
        }
    }

    private func row(_ source: CalendarSource) -> some View {
        let isOn = store.isVisible(source.id)
        return Button {
            withAnimation(Theme.Motion.content) {
                store.setVisible(source.id, !isOn)
            }
        } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(isOn ? colour(source) : .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .strokeBorder(colour(source), lineWidth: Theme.Metrics.Control.borderWidth)
                    )
                    .frame(width: 8, height: 8)
                Text(source.title)
                    .font(Theme.Text.caption)
                    .foregroundStyle(isOn ? Theme.Colors.textPrimary : Theme.Colors.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(source.accountTitle)
                    .font(Theme.Text.micro)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: Theme.Metrics.Settings.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(source.title), \(source.accountTitle)")
        .accessibilityValue(isOn ? "Shown" : "Hidden")
    }

    private func colour(_ source: CalendarSource) -> Color {
        source.color.map { Color(cgColor: $0) } ?? Theme.Colors.textSecondary
    }
}
