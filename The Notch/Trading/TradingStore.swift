import AppKit
import Combine
import Foundation

@MainActor final class TradingStore: ObservableObject {
    @Published private(set) var watchlist: [TradingInstrument]
    @Published private(set) var pinnedID: String?
    @Published private(set) var selectedID: String?
    @Published private(set) var showInNotch: Bool
    @Published private(set) var quotes: [String: MarketQuote] = [:]
    @Published private(set) var rejectedSubscriptions: Set<String> = []
    @Published var message: String?
    private let preferences: TradingPreferences
    private let providers: [TradingFeed: any MarketDataProvider]
    private var streams: [TradingFeed: TradingStreamController] = [:]
    @Published private(set) var connections: [TradingFeed: TradingConnection] = [:]
    private var panelVisible = false
    private var sleeping = false
    private var subscribed: [String] = []
    private var pending: [String: MarketQuote] = [:]
    private var flush: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []

    init(preferences: TradingPreferences, provider: any MarketDataProvider) {
        self.preferences = preferences; self.providers = [.binance: provider]
        let saved = preferences.load()
        watchlist = saved.watchlist; pinnedID = saved.pinnedID; selectedID = saved.selectedID; showInNotch = saved.showInNotch
        for (feed, provider) in self.providers {
            let stream = TradingStreamController(provider: provider)
            stream.onState = { [weak self] state in
                guard let self else { return }
                if state != .connected {
                    for item in self.watchlist where item.feed == feed {
                        self.pending[item.id] = nil
                        if var quote = self.quotes[item.id] { quote.delivery = .unknown; self.quotes[item.id] = quote }
                    }
                }
                self.connections[feed] = state
            }
            stream.onQuote = { [weak self] in self?.receive($0) }
            stream.onSubscriptionFailures = { [weak self] ids in
                guard let self else { return }
                self.rejectedSubscriptions = self.rejectedSubscriptions.filter { id in self.watchlist.first { $0.id == id }?.feed != feed }
                self.rejectedSubscriptions.formUnion(ids)
            }
            streams[feed] = stream
        }
    }

    convenience init() {
        self.init(preferences: TradingPreferences(), provider: BinanceSpotProvider())
    }

    var pinnedInstrument: TradingInstrument? { watchlist.first { $0.id == pinnedID } }
    var selectedInstrument: TradingInstrument? { watchlist.first { $0.id == selectedID } ?? watchlist.first }
    var wantsShoulder: Bool { showInNotch && pinnedInstrument != nil }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setSleeping(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setSleeping(false) }
        })
        reconcile()
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        streams.values.forEach { $0.stop() }; flush?.cancel(); flush = nil; pending.removeAll(); subscribed = []; activeGroups.removeAll()
    }

    func setSleeping(_ value: Bool) { sleeping = value; reconcile(force: true) }
    func setPanelVisible(_ value: Bool) { guard panelVisible != value else { return }; panelVisible = value; reconcile() }
    func setShowInNotch(_ value: Bool) { showInNotch = value; persist(); reconcile() }
    func select(_ id: String) { guard watchlist.contains(where: { $0.id == id }) else { return }; selectedID = id; persist() }
    func pin(_ id: String) {
        guard watchlist.contains(where: { $0.id == id }) else { return }
        pinnedID = pinnedID == id ? nil : id
        if pinnedID != nil { showInNotch = true }
        persist(); reconcile()
    }
    func add(_ item: TradingInstrument) {
        guard item.feed == .binance else { return }
        guard !watchlist.contains(where: { $0.id == item.id }) else { select(item.id); return }
        guard watchlist.count < 100 else { message = "Your watchlist is full (100 instruments)."; return }
        watchlist.append(item); selectedID = item.id
        persist(); reconcile()
    }
    func remove(_ id: String) {
        watchlist.removeAll { $0.id == id }; quotes[id] = nil; pending[id] = nil
        if pinnedID == id { pinnedID = nil }
        if selectedID == id { selectedID = watchlist.first?.id }
        persist(); reconcile()
    }

    func retry() { reconcile(force: true) }

    func search(_ query: String) async throws -> [TradingInstrument] {
        guard let provider = providers[.binance] else { return [] }
        return try await provider.search(query)
    }

    func status(for instrument: TradingInstrument, at now: Date) -> String {
        let feed = instrument.feed
        if feed == .unavailable { return "Live feed unavailable" }
        if rejectedSubscriptions.contains(instrument.id) { return "Symbol unavailable on \(feed.label)" }
        let state: TradingConnection = subscribed.contains(instrument.id) ? connections[feed] ?? .idle : sleeping ? .offline : .idle
        if let quote = quotes[instrument.id] {
            let status = quote.status(at: now, connection: state)
            if status == "Live" { return "Binance live" }
            return status
        }
        return state.label
    }

    private func persist() {
        preferences.save(watchlist: watchlist, pinnedID: pinnedID, selectedID: selectedID, showInNotch: showInNotch)
    }

    private func reconcile(force: Bool = false) {
        let wanted = sleeping ? [] : (panelVisible ? watchlist : (showInNotch ? pinnedInstrument.map { [$0] } ?? [] : []))
        let supported = wanted.filter { $0.feed == .binance }
        let old = subscribed
        subscribed = supported.map(\.id).sorted()
        for feed in TradingFeed.connectedFeeds {
            let items = supported.filter { $0.feed == feed }
            // Removed instruments may no longer be in watchlist; compare controller's saved group.
            let ids = items.map(\.id).sorted()
            guard force || ids != activeGroups[feed, default: []] else { continue }
            activeGroups[feed] = ids
            for id in Set(old + subscribed) where watchlist.first(where: { $0.id == id })?.feed == feed {
                pending[id] = nil; rejectedSubscriptions.remove(id)
                // Old live data cannot become live again merely because a new socket is ready.
                if var quote = quotes[id] { quote.delivery = .unknown; quotes[id] = quote }
            }
            streams[feed]?.start(items)
            if sleeping { connections[feed] = .offline }
        }
    }
    private var activeGroups: [TradingFeed: [String]] = [:]

    private func receive(_ quote: MarketQuote) {
        guard subscribed.contains(quote.instrumentID), watchlist.contains(where: { $0.id == quote.instrumentID }) else { return }
        let previous = pending[quote.instrumentID] ?? quotes[quote.instrumentID]
        if let previous {
            guard quote.timestamp > previous.timestamp || (quote.timestamp == previous.timestamp && previous.delivery != .realtime && quote.delivery == .realtime) else { return }
        }
        pending[quote.instrumentID] = quote
        guard flush == nil else { return }
        flush = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self else { return }
            for (id, value) in pending { quotes[id] = value }
            pending.removeAll(); flush = nil
        }
    }

    #if DEBUG
    /// Only used by offscreen render fixtures. Never compiled into release builds.
    func seedPreviewQuotes(_ values: [MarketQuote]) {
        quotes = Dictionary(uniqueKeysWithValues: values.map { ($0.instrumentID, $0) })
        subscribed = values.map(\.instrumentID)
        for feed in TradingFeed.connectedFeeds { connections[feed] = .connected }
    }
    #endif
}
