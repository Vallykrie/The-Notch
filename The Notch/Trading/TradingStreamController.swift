import Foundation

/// Owns the current Binance stream generation, renewal, and retry loop.
@MainActor final class TradingStreamController {
    private let provider: any MarketDataProvider
    private let sleep: (Double) async throws -> Void
    private var task: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var generation = UUID()
    var onQuote: ((MarketQuote) -> Void)?
    var onState: ((TradingConnection) -> Void)?
    var onSubscriptionFailures: (([String]) -> Void)?

    init(provider: any MarketDataProvider, sleep: @escaping (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.provider = provider
        self.sleep = sleep
    }

    func stop() {
        generation = UUID()
        task?.cancel(); task = nil
        renewal?.cancel(); renewal = nil
        onState?(.idle)
    }

    func start(_ instruments: [TradingInstrument]) {
        stop()
        guard !instruments.isEmpty else { return }
        let token = generation
        onState?(.connecting)
        if let lifetime = provider.connectionLifetime {
            renewal = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(lifetime)) } catch { return }
                guard let self, self.generation == token else { return }
                self.start(instruments)
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled, generation == token {
                do {
                    for try await event in provider.open(instruments) {
                        guard generation == token, !Task.isCancelled else { return }
                        switch event {
                        case .subscriptionFailures(let ids): onSubscriptionFailures?(ids)
                        case .ready:
                            onState?(.connected)
                        case .quote(let quote):
                            attempt = 0
                            onState?(.connected)
                            onQuote?(quote)
                        }
                    }
                    if Task.isCancelled || generation != token { return }
                    throw TradingDataError.disconnected
                } catch {
                    guard generation == token, !Task.isCancelled else { return }
                    let failure = error as? TradingDataError ?? .disconnected
                    if !failure.canRetry {
                        renewal?.cancel()
                        onState?(.failed(failure.localizedDescription))
                        return
                    }
                    onState?(.reconnecting)
                    do { try await sleep(Self.retryDelay(attempt: attempt)) } catch { return }
                    attempt += 1
                }
            }
        }
    }

    static func retryDelay(attempt: Int) -> Double {
        min(30, pow(2, Double(min(attempt, 5))) * Double.random(in: 0.85...1.15))
    }
}
