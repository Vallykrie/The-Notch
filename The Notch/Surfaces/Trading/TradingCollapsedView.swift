import SwiftUI

@MainActor struct TradingCollapsedView: View {
    @ObservedObject var store: TradingStore
    let leading: Bool

    var body: some View {
        if let instrument = store.pinnedInstrument {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let quote = store.quotes[instrument.id]
                let status = store.status(for: instrument, at: context.date)
                Group {
                    if leading {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(instrument.symbol).font(Theme.Text.caption).lineLimit(1).minimumScaleFactor(0.7)
                            if !instrument.symbol.contains("/") {
                                Text(instrument.currency).font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text(quote.map { TradingPriceFormatter.price($0.price, compact: true) } ?? "—")
                                .font(Theme.Text.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.65)
                            if !["Live", "Binance live"].contains(status) {
                                Image(systemName: "clock").font(Theme.Text.micro).foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        .foregroundStyle(["Live", "Binance live"].contains(status) ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                    }
                }
                .help("\(instrument.symbol) · \(instrument.currency) · \(instrument.sourceLabel)\n\(status)")
                .accessibilityLabel(leading ? instrument.symbol : "\(quote.map { TradingPriceFormatter.price($0.price) } ?? "No price") \(instrument.currency), \(status)")
            }
        } else { Color.clear }
    }
}
