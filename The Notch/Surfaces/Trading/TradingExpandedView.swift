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
            } else {
                HStack {
                    Text("Watchlist").font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                    Text("\(store.watchlist.count) \(store.watchlist.count == 1 ? "pair" : "pairs")").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textTertiary)
                    Spacer()
                    Button("Add pair", systemImage: "plus") { searching = true }
                }
                .font(Theme.Text.micro).buttonStyle(.plain)

                if let instrument = store.selectedInstrument {
                    HStack(alignment: .top, spacing: 18) {
                        detail(instrument).frame(width: Theme.Metrics.Trading.detailWidth, alignment: .leading)
                        Rectangle().fill(Theme.Colors.textTertiary.opacity(0.25)).frame(width: 1)
                        watchlist
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Keep a price in sight.").font(Theme.Text.title)
                        Text("Track Binance Spot pairs without an account or API key.")
                            .font(Theme.Text.caption).foregroundStyle(Theme.Colors.textSecondary)
                        Button("Add your first pair") {
                            searching = true
                        }.buttonStyle(.plain).font(Theme.Text.caption)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedBottomContentInset)
        .onChange(of: searching) { _, value in setEditing(value && isVisible) }
        .onChange(of: isVisible) { _, visible in
            if !visible { searching = false; setEditing(false) }
        }
        .onDisappear { setEditing(false) }
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
