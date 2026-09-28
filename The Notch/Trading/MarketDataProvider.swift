import Foundation

nonisolated enum TradingFeedEvent: Equatable, Sendable {
    case quote(MarketQuote)
    case ready
    case subscriptionFailures([String])
}

nonisolated enum TradingDataError: Error, LocalizedError, Sendable {
    case credential, entitlement, rateLimit, invalidResponse, disconnected
    var errorDescription: String? {
        switch self {
        case .credential: "Binance public feed rejected this request."
        case .entitlement: "Pair unavailable on Binance Spot."
        case .rateLimit: "Binance request limit reached. Try again later."
        case .invalidResponse: "Binance returned an invalid response."
        case .disconnected: "Connection interrupted."
        }
    }
    var canRetry: Bool {
        switch self {
        case .credential, .entitlement, .rateLimit: false
        case .invalidResponse, .disconnected: true
        }
    }
}

@MainActor
protocol MarketDataProvider {
    var connectionLifetime: Double? { get }
    func search(_ query: String) async throws -> [TradingInstrument]
    func open(_ instruments: [TradingInstrument]) -> AsyncThrowingStream<TradingFeedEvent, Error>
}

@MainActor extension MarketDataProvider {
    var connectionLifetime: Double? { nil }
}
