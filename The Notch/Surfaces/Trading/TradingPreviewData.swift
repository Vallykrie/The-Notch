import Foundation

/// Preview stores use isolated volatile defaults and an inert provider.
@MainActor enum TradingPreviewData {
    static func emptyStore() -> TradingStore {
        let name = "com.thenotch.preview.trading.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return TradingStore(preferences: TradingPreferences(defaults: defaults), provider: PreviewProvider())
    }

    static func populatedStore() -> TradingStore {
        let store = emptyStore()
        store.add(TradingInstrument(provider: "binance", symbol: "BTC/USDT", name: "Bitcoin", exchange: "Binance", mic: "", currency: "USDT", assetClass: .crypto))
        store.add(TradingInstrument(provider: "binance", symbol: "ETH/USDT", name: "Ethereum", exchange: "Binance", mic: "", currency: "USDT", assetClass: .crypto))
        if let first = store.watchlist.first { store.select(first.id); store.pin(first.id) }
        #if DEBUG
        let prices: [Decimal] = [64250.50, 3420.35]
        store.seedPreviewQuotes(zip(store.watchlist, prices).map { item, price in
            MarketQuote(instrumentID: item.id, price: price, timestamp: Date(), receivedAt: Date(), delivery: .realtime)
        })
        #endif
        return store
    }

    private final class PreviewProvider: MarketDataProvider {
        func search(_ query: String) async throws -> [TradingInstrument] { [] }
        func open(_ instruments: [TradingInstrument]) -> AsyncThrowingStream<TradingFeedEvent, Error> { AsyncThrowingStream { $0.finish() } }
    }
}
