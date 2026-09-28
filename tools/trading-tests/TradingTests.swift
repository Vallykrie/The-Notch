import Foundation

@main
struct TradingTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func main() async throws {
        check(LiveActivityLayout(hasMedia: true, hasAgents: true, hasHUD: false, hasTrading: true, agentNeedsAttention: false) == .trading, "pinned crypto wins over ordinary activity")
        check(LiveActivityLayout(hasMedia: true, hasAgents: true, hasHUD: true, hasTrading: true, agentNeedsAttention: true) == .systemHUD, "HUD wins over crypto")
        check(LiveActivityLayout(hasMedia: true, hasAgents: true, hasHUD: false, hasTrading: true, agentNeedsAttention: true) == .agentsOnly, "agent attention wins over crypto")

        let btc = TradingInstrument(provider: "binance", symbol: "BTC/USDT", name: "Bitcoin", exchange: "Binance", mic: "", currency: "USDT", assetClass: .crypto)
        let eth = TradingInstrument(provider: "binance", symbol: "ETH/USDT", name: "Ethereum", exchange: "Binance", mic: "", currency: "USDT", assetClass: .crypto)
        let stock = TradingInstrument(symbol: "AAPL", name: "Apple", exchange: "NASDAQ", mic: "XNAS", currency: "USD", assetClass: .stock)
        let forex = TradingInstrument(provider: "mt5", symbol: "EURUSD", name: "Euro", exchange: "MetaQuotes-Demo", mic: "", currency: "USD", assetClass: .forex)
        check(btc.feed == .binance && stock.feed == .unavailable && forex.feed == .unavailable, "only crypto routes to a live feed")

        let suite = "com.thenotch.crypto-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = TradingPreferences(defaults: defaults)
        var legacy = TradingPreferences.Saved(watchlist: [stock, btc, forex, eth, btc], pinnedID: stock.id, selectedID: forex.id, showInNotch: true)
        legacy.version = 2
        let original = try JSONEncoder().encode(legacy)
        defaults.set(original, forKey: "NotchTradingPreferences.v2")
        let migrated = prefs.load()
        check(migrated.watchlist == [btc, eth], "old watchlist migrates to distinct crypto pairs")
        check(migrated.pinnedID == nil && migrated.selectedID == btc.id, "removed assets cannot stay pinned or selected")
        check(defaults.data(forKey: "NotchTradingPreferences.preCryptoBackup") == original, "old watchlist has a recovery backup")
        check(defaults.data(forKey: "NotchTradingPreferences.v3") != nil, "crypto-only preferences use a new version")
        prefs.save(watchlist: [eth, stock, btc], pinnedID: eth.id, selectedID: eth.id, showInNotch: true)
        let saved = prefs.load()
        check(saved.watchlist == [eth, btc] && saved.pinnedID == eth.id, "saved watchlist remains crypto-only")
        check(defaults.data(forKey: "NotchTradingPreferences.preCryptoBackup") == original, "later saves preserve the recovery backup")

        let catalog = Data(#"{"symbols":[{"symbol":"BTCUSDT","status":"TRADING","baseAsset":"BTC","quoteAsset":"USDT","isSpotTradingAllowed":true},{"symbol":"ETHUSDT","status":"BREAK","baseAsset":"ETH","quoteAsset":"USDT"}]}"#.utf8)
        let decoded = try BinanceSpotProvider.decodeSymbols(catalog)
        check(decoded.count == 1 && decoded[0].id == btc.id, "Binance search keeps exact active Spot pairs")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let ticker = Data(#"{"e":"24hrTicker","s":"BTCUSDT","E":1700000000000,"c":"102.12345678","P":"2.12345678"}"#.utf8)
        let quotes = try BinanceSpotProvider.decodeTicker(ticker, instruments: [btc, eth], now: now)
        check(quotes.count == 1 && quotes[0].instrumentID == btc.id && quotes[0].price == Decimal(string: "102.12345678"), "Binance tick maps to one exact pair with full precision")
        check(quotes[0].changePercent == Decimal(string: "2.12345678"), "Binance tick uses rolling 24-hour change")
        check(quotes[0].status(at: now.addingTimeInterval(90), connection: .connected) != "Live", "stale tick loses live status")
        check(TradingPriceFormatter.price(Decimal(string: "0.0000000123")!, compact: true) != "0.00", "small crypto price does not round to zero")

        let isolated = UserDefaults(suiteName: suite + ".store")!
        defer { isolated.removePersistentDomain(forName: suite + ".store") }
        let provider = ControlledProvider()
        let store = TradingStore(preferences: TradingPreferences(defaults: isolated), provider: provider)
        store.add(stock)
        store.add(forex)
        check(store.watchlist.isEmpty, "store rejects noncrypto additions")
        store.add(btc)
        store.pin(btc.id)
        check(store.watchlist == [btc] && store.pinnedInstrument?.id == btc.id && store.showInNotch, "crypto pair can be pinned")
        store.setPanelVisible(true)
        for _ in 0..<20 { await Task.yield() }
        let live = MarketQuote(instrumentID: btc.id, price: 120, timestamp: Date(), receivedAt: Date(), delivery: .realtime, rollingChangePercent: 3)
        provider.continuation?.yield(.quote(live))
        try await Task.sleep(for: .milliseconds(350))
        check(store.quotes[btc.id]?.price == 120, "public crypto stream updates the watchlist")
        var older = live
        older.timestamp.addTimeInterval(-1)
        older.price = 90
        provider.continuation?.yield(.quote(older))
        try await Task.sleep(for: .milliseconds(300))
        check(store.quotes[btc.id]?.price == 120, "older Binance tick cannot roll back the price")
        store.setSleeping(true)
        check(store.connections[.binance] == .offline, "sleep marks crypto offline")
        store.remove(btc.id)
        provider.continuation?.yield(.quote(live))
        try await Task.sleep(for: .milliseconds(350))
        check(store.watchlist.isEmpty && store.pinnedInstrument == nil && store.quotes[btc.id] == nil, "removed pair cannot revive from late tick")
        store.stop()

        guard failures == 0 else { throw TestFailure.count(failures) }
    }

    enum TestFailure: Error { case count(Int) }
}

@MainActor
private final class ControlledProvider: MarketDataProvider {
    var continuation: AsyncThrowingStream<TradingFeedEvent, Error>.Continuation?

    func search(_ query: String) async throws -> [TradingInstrument] { [] }
    func open(_ instruments: [TradingInstrument]) -> AsyncThrowingStream<TradingFeedEvent, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
            continuation.yield(.ready)
        }
    }
}
