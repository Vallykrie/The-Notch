import Foundation

nonisolated struct TradingInstrument: Codable, Hashable, Identifiable, Sendable {
    enum AssetClass: String, Codable, CaseIterable, Sendable {
        case stock = "Stocks", crypto = "Crypto", forex = "Forex"
    }
    var provider: String = "twelvedata"
    var symbol: String
    var name: String
    var exchange: String
    var mic: String
    var currency: String
    var assetClass: AssetClass

    var id: String { [provider, assetClass.rawValue, mic, exchange, symbol, currency].joined(separator: "|") }
    // Stock and forex cases remain decodable so older watchlists can be archived during migration.
    var feed: TradingFeed { assetClass == .crypto ? .binance : .unavailable }
    var feedSymbol: String { symbol.replacingOccurrences(of: "/", with: "").uppercased() }
    var sourceLabel: String { feed.label }
    var changeLabel: String { "24h" }
}

nonisolated enum TradingFeed: String, CaseIterable, Codable, Sendable {
    case binance, unavailable
    var label: String {
        switch self {
        case .binance: "Binance Spot"
        case .unavailable: "Live unavailable"
        }
    }
    static let connectedFeeds: [Self] = [.binance]
}
