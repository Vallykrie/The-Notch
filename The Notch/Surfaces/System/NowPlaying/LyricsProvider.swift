import Foundation

/// Lyrics for one track: time-stamped lines when they exist, plain text otherwise.
nonisolated struct Lyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        let time: TimeInterval
        let text: String
    }

    /// In playback order. Empty when only plain lyrics were found.
    let synced: [Line]
    let plain: [String]
    let isInstrumental: Bool

    var isSynced: Bool { !synced.isEmpty }

    /// The index of the line being sung at `position`: the last line that has started. `nil`
    /// before the first line, during the intro.
    func lineIndex(at position: TimeInterval) -> Int? {
        guard let first = synced.first, position >= first.time else { return nil }
        var low = 0
        var high = synced.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if synced[mid].time <= position { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Parses LRC: `[mm:ss.xx] text`, possibly several stamps per line. Lines without a stamp
    /// (metadata such as `[ar:…]`, or blanks) are skipped.
    static func parseLRC(_ source: String) -> [Line] {
        var lines: [Line] = []
        for raw in source.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var stamps: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let stamp = rest[rest.index(after: rest.startIndex)..<close]
                guard let time = timestamp(stamp) else { break }
                stamps.append(time)
                rest = rest[rest.index(after: close)...]
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            for time in stamps { lines.append(Line(time: time, text: text)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    private static func timestamp(_ stamp: Substring) -> TimeInterval? {
        let parts = stamp.split(separator: ":")
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }
}

nonisolated enum LyricsLookup: Equatable, Sendable {
    case found(Lyrics)
    case notFound
    case failed
}

/// Fetches lyrics from LRCLIB (lrclib.net): free, keyless, and the largest open source of
/// time-synced lyrics. Neither Spotify nor Music exposes lyrics through scripting — Music's
/// `lyrics` property only holds what a user typed into a local file — so a lookup by title,
/// artist and duration is the only route that works for both players.
///
/// Nothing is sent until the user opens the lyrics view: this is the app's second network
/// call, after Spotify's artwork, and it carries the track and artist names, so it happens
/// only when asked for. Results are cached per track for the life of the app.
actor LyricsProvider {
    static let shared = LyricsProvider()

    private var cache: [String: LyricsLookup] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.httpAdditionalHeaders = [
            // LRCLIB asks clients to identify themselves.
            "User-Agent": "The Notch (https://github.com/Vallykrie/The-Notch)",
        ]
        session = URLSession(configuration: configuration)
    }

    /// `ignoringCache` is for an explicit retry: a "not found" is cached, and the user asking
    /// again is the one reason to believe that answer might have changed.
    func lyrics(
        title: String,
        artist: String,
        duration: TimeInterval?,
        ignoringCache: Bool = false
    ) async -> LyricsLookup {
        let key = "\(title)\u{1F}\(artist)"
        if !ignoringCache, let cached = cache[key] { return cached }

        var result = await search(title: title, artist: artist, duration: duration)
        // Players decorate titles that the lyrics database stores bare — Spotify's
        // `I See the Light - From "Tangled" / Soundtrack Version`, `Song - Remastered 2011`,
        // `Song (feat. Someone)`. Only tried when the full title finds nothing, so a song
        // whose real name contains a dash is matched as itself first.
        if result == .notFound, let bare = Self.bareTitle(title), bare != title {
            result = await search(title: bare, artist: artist, duration: duration)
        }
        // A failure is not cached: a timeout or an offline Mac should be retried.
        if result != .failed { cache[key] = result }
        return result
    }

    private func search(title: String, artist: String, duration: TimeInterval?) async -> LyricsLookup {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = components.url else { return .failed }

        do {
            let (data, response) = try await session.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .failed }
            let records = try JSONDecoder().decode([Record].self, from: data)
            return Self.best(of: records, duration: duration).map { .found($0) } ?? .notFound
        } catch {
            return .failed
        }
    }

    /// The title with a player's decorations removed: anything after ` - `, and any trailing
    /// `(…)` or `[…]`. `nil` when nothing is left.
    static func bareTitle(_ title: String) -> String? {
        var bare = title
        if let dash = bare.range(of: " - ") { bare = String(bare[..<dash.lowerBound]) }
        while let last = bare.last, last == ")" || last == "]",
              let open = bare.lastIndex(of: last == ")" ? "(" : "[") {
            bare = String(bare[..<open])
            bare = bare.trimmingCharacters(in: .whitespaces)
        }
        bare = bare.trimmingCharacters(in: .whitespaces)
        return bare.isEmpty ? nil : bare
    }

    private struct Record: Decodable {
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// Prefers synced lyrics, then the record whose length is closest to the playing track —
    /// search returns live versions, remasters and covers under the same title.
    private static func best(of records: [Record], duration: TimeInterval?) -> Lyrics? {
        func distance(_ record: Record) -> Double {
            guard let duration, let length = record.duration else { return .greatestFiniteMagnitude / 2 }
            return abs(length - duration)
        }
        // A record more than 10s off is a different recording, whatever its title says.
        let plausible = records.filter { distance($0) <= 10 || duration == nil }
        let candidates = plausible.isEmpty ? records : plausible
        let ranked = candidates.sorted { left, right in
            let leftSynced = !(left.syncedLyrics ?? "").isEmpty
            let rightSynced = !(right.syncedLyrics ?? "").isEmpty
            if leftSynced != rightSynced { return leftSynced }
            return distance(left) < distance(right)
        }
        guard let record = ranked.first else { return nil }

        let synced = Lyrics.parseLRC(record.syncedLyrics ?? "")
        let plain = (record.plainLyrics ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let instrumental = record.instrumental ?? false
        guard !synced.isEmpty || !plain.isEmpty || instrumental else { return nil }
        return Lyrics(synced: synced, plain: plain, isInstrumental: instrumental)
    }
}
