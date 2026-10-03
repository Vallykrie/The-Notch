import SwiftUI

@MainActor struct TradingExpandedView: View {
    @ObservedObject var store: TradingStore
    var isVisible: Bool
    var setEditing: (Bool) -> Void
    @State private var searching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if searching {
                TradingSearchView(store: store) { searching = false }
            } else if store.watchlist.isEmpty {
                emptyState
            } else if let instrument = store.selectedInstrument {
                twoColumns {
                    detail(instrument)
                } right: {
                    // The header belongs to the list it counts, so it heads the right column
                    // rather than spanning both.
                    VStack(alignment: .leading, spacing: 6) {
                        watchlistHeader
                        watchlist
                    }
                }
            }
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding + Theme.Metrics.Trading.contentInset)
        // The same bottom clearance as the media panel, so the hairline between the columns
        // stops short of the bottom curve instead of running into it.
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
        .onChange(of: searching) { _, value in setEditing(value && isVisible) }
        .onChange(of: isVisible) { _, visible in
            if !visible { searching = false; setEditing(false) }
        }
        .onDisappear { setEditing(false) }
    }

    /// Two columns either side of a hairline, centred in the panel as one block — the way the
    /// media and agents empty states sit level with their artwork — rather than pinned to the
    /// top with the bottom third of the panel empty.
    ///
    /// The centred form sizes the block to its content, which is what lets the hairline match
    /// the taller column. A watchlist too long for that falls back to the full-height layout,
    /// where the list scrolls.
    private func twoColumns<Left: View, Right: View>(
        alignment: VerticalAlignment = .top,
        @ViewBuilder left: () -> Left,
        @ViewBuilder right: () -> Right
    ) -> some View {
        let left = left()
        let right = right()
        return ViewThatFits(in: .vertical) {
            columnRow(left, right, alignment: alignment)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: .infinity, alignment: .center)
            columnRow(left, right, alignment: alignment)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func columnRow(_ left: some View, _ right: some View, alignment: VerticalAlignment) -> some View {
        HStack(alignment: alignment, spacing: 18) {
            left.frame(width: Theme.Metrics.Trading.detailWidth, alignment: .leading)
            Rectangle().fill(Theme.Colors.textTertiary.opacity(0.25)).frame(width: 1)
            right.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var watchlistHeader: some View {
        HStack {
            Text("Watchlist").font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
            Text("\(store.watchlist.count) \(store.watchlist.count == 1 ? "pair" : "pairs")").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
            Spacer()
            Button("Add pair", systemImage: "plus") { searching = true }
        }
        .font(Theme.Text.micro).buttonStyle(.plain)
    }

    /// The same two columns as a populated watchlist — the pitch where the price detail goes,
    /// suggestions where the rows go — so adding the first pair swaps content in place.
    ///
    /// The old version stacked a "Watchlist · 0 pairs · + Add pair" header over a second "Add
    /// your first pair" link: the same action twice, neither of them looking like a button.
    /// The pitch is centred against the suggestions rather than top-aligned: the list is the
    /// taller column, and a short pitch pinned to its top left the lower half of the panel bare.
    private var emptyState: some View {
        twoColumns(alignment: .center) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Keep a price in sight.").font(Theme.Text.title)
                Text("Live Binance Spot prices.\nNo account, no API key.")
                    .font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("+ Add a pair") { searching = true }
                    .buttonStyle(.notchCompact)
                    .padding(.top, 2)
            }
        } right: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Popular").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.horizontal, 6)
                ForEach(Self.suggestions) { suggestionRow($0) }
            }
        }
    }

    /// Laid out like a watchlist row, dimmed, with "+ Add" where the price and remove mark go.
    /// No price: fetching quotes for pairs the user has not asked for would put the app on the
    /// network before they have opted into anything. The placeholder dash that used to stand in
    /// for it sat beside the plus and read as a minus/plus stepper, so the column says what the
    /// row does instead.
    private func suggestionRow(_ item: TradingInstrument) -> some View {
        Button { store.add(item) } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.symbol).font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                    // The quote currency is already in the symbol (`BTC/USDT`).
                    Text(item.name).font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
                }
                Spacer(minLength: 4)
                Text("+ Add").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(SuggestionRowStyle())
        .accessibilityLabel("Add \(item.symbol) to watchlist")
    }

    private static let suggestions: [TradingInstrument] = [
        ("BTC", "Bitcoin"), ("ETH", "Ethereum"), ("SOL", "Solana"),
    ].map { base, name in
        TradingInstrument(provider: "binance", symbol: "\(base)/USDT", name: name, exchange: "Binance", mic: "", currency: "USDT", assetClass: .crypto)
    }

    private func detail(_ instrument: TradingInstrument) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let quote = store.quotes[instrument.id]
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(instrument.symbol).font(Theme.Text.title).lineLimit(1)
                    Spacer(minLength: 4)
                    Button { store.pin(instrument.id) } label: {
                        Image(systemName: store.pinnedID == instrument.id ? "pin.fill" : "pin")
                    }.buttonStyle(.plain)
                        .help(store.pinnedID == instrument.id ? "Unpin from notch" : "Pin price to notch")
                        .accessibilityLabel(store.pinnedID == instrument.id ? "Unpin \(instrument.symbol)" : "Pin \(instrument.symbol)")
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(quote.map { TradingPriceFormatter.price($0.price) } ?? "—")
                        .font(Theme.Text.tradingPrice).monospacedDigit().lineLimit(1).minimumScaleFactor(0.6)
                        .contentTransition(.identity)
                    Text(instrument.currency).font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
                }
                HStack(spacing: 6) {
                    Text(TradingPriceFormatter.percent(quote?.changePercent))
                        .foregroundStyle(TradingPresentation.changeColor(quote?.changePercent))
                    if quote?.changePercent != nil { Text(instrument.changeLabel).foregroundStyle(Theme.Colors.textTertiary) }
                }.font(Theme.Text.micro)
                HStack(spacing: 5) {
                    Circle().fill(TradingPresentation.statusColor(store.status(for: instrument, at: context.date))).frame(width: 5, height: 5)
                    Text(store.status(for: instrument, at: context.date)).lineLimit(2)
                }.font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
                HStack(spacing: 6) {
                    Text(instrument.sourceLabel).lineLimit(1)
                    if let quote { Text(quote.timestamp, style: .time) }
                }.font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
                    .help(quote.map { "Quote time: \($0.timestamp.formatted()). Source: \(instrument.sourceLabel)." } ?? instrument.name)
            }
        }
    }

    private var watchlist: some View {
        ViewThatFits(in: .vertical) {
            watchlistRows
            ScrollView { watchlistRows }.scrollIndicators(.hidden)
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var watchlistRows: some View {
            VStack(spacing: 3) {
                ForEach(store.watchlist) { item in
                    HStack(spacing: 8) {
                        Button { store.select(item.id) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.symbol).font(Theme.Text.caption)
                                    Text("\(item.sourceLabel)  \(item.currency)").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
                                }
                                Spacer(minLength: 4)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(store.quotes[item.id].map { TradingPriceFormatter.price($0.price, compact: true) } ?? "—")
                                        .font(Theme.Text.caption).monospacedDigit()
                                    Text(TradingPriceFormatter.percent(store.quotes[item.id]?.changePercent))
                                        .font(Theme.Text.micro).foregroundStyle(TradingPresentation.changeColor(store.quotes[item.id]?.changePercent))
                                }
                                if store.pinnedID == item.id { Image(systemName: "pin.fill").font(Theme.Text.micro) }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button { store.remove(item.id) } label: { Image(systemName: "xmark").font(Theme.Text.micro) }
                            .buttonStyle(.plain).foregroundStyle(Theme.Colors.textTertiary)
                            .accessibilityLabel("Remove \(item.symbol) from watchlist")
                    }
                    .padding(.horizontal, 6).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.textPrimary.opacity(store.selectedID == item.id ? 0.08 : 0)))
                }
            }
    }
}

@MainActor enum TradingPresentation {
    static func changeColor(_ value: Decimal?) -> Color {
        guard let value, value != 0 else { return Theme.Colors.textSecondary }
        return value > 0 ? Theme.Colors.tradingUp : Theme.Colors.tradingDown
    }
    static func statusColor(_ status: String) -> Color {
        ["Live", "Binance live"].contains(status) ? Theme.Colors.tradingUp : Theme.Colors.textTertiary
    }
}

/// The watchlist's selected-row fill, borrowed for hover and press on a suggestion, so a
/// suggestion lights up exactly the way the row it becomes will look once selected.
private struct SuggestionRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SuggestionRowBody(configuration: configuration)
    }

    private struct SuggestionRowBody: View {
        let configuration: Configuration
        @State private var hovered = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Theme.Colors.textPrimary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.08 : 0))
                )
                .onHover { hovered = $0 }
                .animation(Theme.Motion.content, value: hovered)
                .animation(Theme.Motion.content, value: configuration.isPressed)
        }
    }
}
