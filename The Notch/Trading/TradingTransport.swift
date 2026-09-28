import Foundation

/// Shared transport. Never forwards raw errors (which can include credentials/URLs).
@MainActor enum TradingTransport {
    static func data(_ request: URLRequest, session: URLSession) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TradingDataError.invalidResponse }
            switch http.statusCode {
            case 200..<300: return data
            case 401: throw TradingDataError.credential
            case 403, 451: throw TradingDataError.entitlement
            case 429: throw TradingDataError.rateLimit
            case 400, 404: throw TradingDataError.entitlement
            default: throw TradingDataError.disconnected
            }
        } catch let error as TradingDataError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw TradingDataError.disconnected }
    }

    static func send(_ payload: [String: Any], to socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: payload)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    static func receive(_ socket: URLSessionWebSocketTask) async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let string): return Data(string.utf8)
        @unknown default: throw TradingDataError.invalidResponse
        }
    }

    static func stream(session: URLSession, request: URLRequest,
                       run: @escaping @MainActor (URLSessionWebSocketTask, AsyncThrowingStream<TradingFeedEvent, Error>.Continuation) async throws -> Void)
        -> AsyncThrowingStream<TradingFeedEvent, Error> {
        let socket = session.webSocketTask(with: request)
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(512)) { continuation in
            let task = Task { @MainActor in
                socket.resume()
                // Pings detect half-open connections even when markets are quiet. A deadline
                // closes a socket whose pong never arrives; URLSession answers server pings.
                let heartbeat = Task { @MainActor in
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(15))
                            let deadline = Task { @MainActor in
                                try await Task.sleep(for: .seconds(10))
                                socket.cancel(with: .goingAway, reason: nil)
                            }
                            defer { deadline.cancel() }
                            try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                                socket.sendPing { error in
                                    if error != nil { result.resume(throwing: TradingDataError.disconnected) }
                                    else { result.resume() }
                                }
                            }
                        }
                    } catch {
                        socket.cancel(with: .goingAway, reason: nil)
                        continuation.finish(throwing: TradingDataError.disconnected)
                    }
                }
                defer { heartbeat.cancel(); socket.cancel(with: .goingAway, reason: nil) }
                do { try await run(socket, continuation); continuation.finish() }
                catch let error as TradingDataError { continuation.finish(throwing: error) }
                catch { continuation.finish(throwing: TradingDataError.disconnected) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel(); socket.cancel(with: .goingAway, reason: nil) }
        }
    }

    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

nonisolated struct FeedDecimal: Decodable {
    let value: Decimal
    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if let text = try? box.decode(String.self), let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) { self.value = value }
        else { value = try box.decode(Decimal.self) }
        guard !value.isNaN else { throw TradingDataError.invalidResponse }
    }
}
