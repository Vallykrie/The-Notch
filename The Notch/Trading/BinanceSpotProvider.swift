import Foundation

@MainActor final class BinanceSpotProvider: MarketDataProvider {
    // Rotate five minutes before Binance's hard 24-hour connection limit.
    let connectionLifetime: Double? = 23 * 3600 + 55 * 60
    private let session: URLSession
    private var catalog: [TradingInstrument] = []
    private var catalogDate = Date.distantPast
    init(session: URLSession = .shared) { self.session = session }

    func search(_ query: String) async throws -> [TradingInstrument] {
        let items = try await symbols()
        let key = query.replacingOccurrences(of: "/", with: "").uppercased()
        return Array(items.filter { $0.feedSymbol.contains(key) || $0.name.localizedCaseInsensitiveContains(query) }.prefix(40))
    }
    private func symbols() async throws -> [TradingInstrument] {
        if Date().timeIntervalSince(catalogDate) < 3600 { return catalog }
        let data = try await TradingTransport.data(TradingTransport.request(URL(string: "https://data-api.binance.vision/api/v3/exchangeInfo")!), session: session)
        catalog = try Self.decodeSymbols(data); catalogDate = Date()
        return catalog
    }
    static func decodeSymbols(_ data: Data) throws -> [TradingInstrument] {
        struct Catalog: Decodable {
            struct Row: Decodable { var symbol: String; var status: String; var baseAsset: String; var quoteAsset: String; var isSpotTradingAllowed: Bool? }
            var symbols: [Row]
        }
        return try JSONDecoder().decode(Catalog.self, from: data).symbols.filter { $0.status == "TRADING" && $0.isSpotTradingAllowed != false }.map {
            TradingInstrument(provider: "binance", symbol: "\($0.baseAsset)/\($0.quoteAsset)", name: $0.baseAsset, exchange: "Binance", mic: "", currency: $0.quoteAsset, assetClass: .crypto)
        }
    }
    func open(_ instruments: [TradingInstrument]) -> AsyncThrowingStream<TradingFeedEvent, Error> {
        // Validate exact pairs first. Binance acknowledges even nonexistent stream names.
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let known = Set(try await symbols().map(\.feedSymbol))
                    let accepted = instruments.filter { known.contains($0.feedSymbol) }
                    let rejected = instruments.filter { !known.contains($0.feedSymbol) }.map(\.id)
                    continuation.yield(.subscriptionFailures(rejected))
                    guard !accepted.isEmpty else { throw TradingDataError.entitlement }
                    var url = URLComponents(string: "wss://data-stream.binance.vision/stream")!
                    url.queryItems = [URLQueryItem(name: "streams", value: Set(accepted.map { $0.feedSymbol.lowercased() + "@ticker" }).sorted().joined(separator: "/"))]
                    let events = TradingTransport.stream(session: session, request: TradingTransport.request(url.url!)) { socket, output in
                        while !Task.isCancelled {
                            let data = try await TradingTransport.receive(socket)
                            for quote in try Self.decodeTicker(data, instruments: accepted, now: Date()) { output.yield(.quote(quote)) }
                        }
                    }
                    for try await event in events { continuation.yield(event) }
                    continuation.finish()
                } catch let error as TradingDataError { continuation.finish(throwing: error) }
                catch { continuation.finish(throwing: TradingDataError.disconnected) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    static func decodeTicker(_ data: Data, instruments: [TradingInstrument], now: Date) throws -> [MarketQuote] {
        struct Ticker: Decodable { var e: String; var s: String; var E: Double; var c: FeedDecimal; var P: FeedDecimal }
        struct Combined: Decodable { var data: Ticker }
        let row = try (try? JSONDecoder().decode(Combined.self, from: data).data) ?? JSONDecoder().decode(Ticker.self, from: data)
        let timestamp = Date(timeIntervalSince1970: row.E / 1000)
        guard row.e == "24hrTicker", row.c.value > 0, row.E > 0, timestamp.timeIntervalSince(now) <= 5 else { throw TradingDataError.invalidResponse }
        return instruments.filter { $0.feedSymbol == row.s }.map {
            MarketQuote(instrumentID: $0.id, price: row.c.value, timestamp: timestamp, receivedAt: now, delivery: .realtime, rollingChangePercent: row.P.value)
        }
    }
}
