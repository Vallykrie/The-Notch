import Foundation

nonisolated enum TradingConnection: Equatable, Sendable {
    case idle, connecting, connected, reconnecting, offline, failed(String)
    var label: String {
        switch self {
        case .idle: "Paused"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .reconnecting: "Reconnecting"
        case .offline: "Offline"
        case .failed(let message): message
        }
    }
}

nonisolated struct MarketQuote: Equatable, Sendable {
    enum Delivery: String, Sendable { case realtime, unknown }
    var instrumentID: String
    var price: Decimal
    var timestamp: Date
    var receivedAt: Date
    var delivery: Delivery
    var rollingChangePercent: Decimal? = nil
    var changePercent: Decimal? { rollingChangePercent }

    func status(at now: Date, connection: TradingConnection) -> String {
        switch connection {
        case .offline, .reconnecting, .connecting, .failed: return connection.label
        default: break
        }
        guard connection == .connected else { return "Last quote" }
        guard now.timeIntervalSince(timestamp) < 30, timestamp.timeIntervalSince(now) <= 5 else { return "Last quote" }
        return delivery == .realtime ? "Live" : "Latency unverified"
    }
}
