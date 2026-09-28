import Foundation

@MainActor
final class TradingPreferences {
    struct Saved: Codable {
        var version = 3
        var watchlist: [TradingInstrument] = []
        var pinnedID: String?
        var selectedID: String?
        var showInNotch = false
    }
    private let defaults: UserDefaults
    private let key = "NotchTradingPreferences.v3"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func load() -> Saved {
        let previous = defaults.data(forKey: "NotchTradingPreferences.v2") ?? defaults.data(forKey: "NotchTradingPreferences.v1")
        guard let data = defaults.data(forKey: key) ?? previous,
              let saved = try? JSONDecoder().decode(Saved.self, from: data), (1...3).contains(saved.version) else { return Saved() }
        if defaults.data(forKey: key) == nil, let previous,
           defaults.data(forKey: "NotchTradingPreferences.preCryptoBackup") == nil {
            defaults.set(previous, forKey: "NotchTradingPreferences.preCryptoBackup")
        }
        var migrated = normalized(saved)
        migrated.version = 3
        if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: key) }
        return migrated
    }

    func save(watchlist: [TradingInstrument], pinnedID: String?, selectedID: String?, showInNotch: Bool) {
        let saved = normalized(Saved(watchlist: watchlist, pinnedID: pinnedID, selectedID: selectedID, showInNotch: showInNotch))
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: key) }
    }

    private func normalized(_ value: Saved) -> Saved {
        var result = value
        var seen = Set<String>()
        result.watchlist = value.watchlist.filter { $0.assetClass == .crypto && !$0.symbol.isEmpty && seen.insert($0.id).inserted }
        if !result.watchlist.contains(where: { $0.id == result.pinnedID }) { result.pinnedID = nil }
        if !result.watchlist.contains(where: { $0.id == result.selectedID }) { result.selectedID = result.watchlist.first?.id }
        return result
    }
}
