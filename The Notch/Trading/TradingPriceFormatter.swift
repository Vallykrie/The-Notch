import Foundation

nonisolated enum TradingPriceFormatter {
    static func price(_ value: Decimal, compact: Bool = false) -> String {
        guard !value.isNaN else { return "—" }
        let magnitude = abs(NSDecimalNumber(decimal: value).doubleValue)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = magnitude >= 1 ? 2 : 0
        formatter.maximumFractionDigits = magnitude >= 1 ? (compact ? 5 : 8) : 12
        if compact, magnitude >= 1_000_000 {
            let scale: Decimal = magnitude >= 1_000_000_000 ? 1_000_000_000 : 1_000_000
            formatter.maximumFractionDigits = 2
            return (formatter.string(from: NSDecimalNumber(decimal: value / scale)) ?? "—") + (scale == 1_000_000 ? "M" : "B")
        }
        if magnitude > 0 && magnitude < 0.000000000001 {
            formatter.numberStyle = .scientific
            formatter.maximumFractionDigits = 4
        }
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—"
    }

    static func percent(_ value: Decimal?) -> String {
        guard let value, !value.isNaN else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return (value > 0 ? "+" : "") + (formatter.string(from: NSDecimalNumber(decimal: value)) ?? "—") + "%"
    }
}
