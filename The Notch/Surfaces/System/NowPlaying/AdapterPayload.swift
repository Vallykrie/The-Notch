import Foundation

/// One JSON value from the adapter. The payload is flat, so nested containers never occur;
/// they decode as `.unsupported` rather than failing the whole line.
nonisolated enum AdapterValue: Decodable, Equatable, Sendable {
    case bool(Bool)
    case number(Double)
    case string(String)
    case null
    case unsupported

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .unsupported
        }
    }

    var string: String? {
        if case let .string(value) = self { value } else { nil }
    }

    var number: Double? {
        if case let .number(value) = self, value.isFinite { value } else { nil }
    }

    var bool: Bool? {
        switch self {
        case let .bool(value): value
        case let .number(value): value != 0
        default: nil
        }
    }
}

/// One line of `stream` output: `{"type":"data","diff":true,"payload":{…}}`.
nonisolated struct AdapterLine: Decodable, Sendable {
    let type: String?
    let diff: Bool?
    let payload: [String: AdapterValue]?
}

/// The adapter's view of the current now-playing item, rebuilt from its diffed stream.
///
/// `stream --micros` sends a full snapshot first and then only the keys that changed, with
/// `null` meaning a key was removed. An empty full snapshot means nothing holds the system's
/// media controls. Artwork arrives base64-encoded, often in a later line than the metadata; it is
/// decoded here, once per change, so the main actor only ever sees bytes.
nonisolated struct AdapterSnapshot: Sendable {
    /// The same defensive cap the AppleScript path applies to artwork.
    static let maximumArtworkByteCount = 4 * 1_024 * 1_024

    private(set) var fields: [String: AdapterValue] = [:]
    private(set) var artwork: Data?

    /// Applies one stream line. Returns false for a line that is not a data line or does not
    /// parse, which leaves the snapshot untouched.
    @discardableResult
    mutating func apply(line: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(AdapterLine.self, from: line),
              decoded.type == nil || decoded.type == "data",
              let payload = decoded.payload
        else { return false }

        if decoded.diff == true {
            for (key, value) in payload {
                if value == .null {
                    fields.removeValue(forKey: key)
                } else {
                    fields[key] = value
                }
            }
        } else {
            fields = payload
        }

        if decoded.diff != true || payload.keys.contains(Self.artworkKey) {
            artwork = fields[Self.artworkKey]?.string.flatMap(Self.decodeArtwork)
        }
        return true
    }

    /// The item this snapshot describes, or nil when nothing is playing or the snapshot lacks
    /// the keys upstream guarantees (a source app and a title).
    var track: AdapterTrack? {
        let source = fields["parentApplicationBundleIdentifier"]?.string
            ?? fields["bundleIdentifier"]?.string
        guard let source, !source.isEmpty,
              let title = fields["title"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }

        let micros = 1_000_000.0
        return AdapterTrack(
            sourceBundleIdentifier: source,
            itemIdentifier: fields["contentItemIdentifier"]?.string,
            title: title,
            artist: fields["artist"]?.string?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            isPlaying: fields["playing"]?.bool ?? false,
            elapsedAtTimestamp: fields["elapsedTimeMicros"]?.number.map { $0 / micros },
            timestamp: fields["timestampEpochMicros"]?.number
                .map { Date(timeIntervalSince1970: $0 / micros) },
            playbackRate: fields["playbackRate"]?.number,
            duration: fields["durationMicros"]?.number.map { $0 / micros }.flatMap {
                $0 > 0 ? $0 : nil
            },
            artwork: artwork
        )
    }

    private static let artworkKey = "artworkData"

    private static func decodeArtwork(_ base64: String) -> Data? {
        // Base64 is 4/3 the size of the bytes it encodes; refuse before decoding.
        guard base64.utf8.count <= maximumArtworkByteCount / 3 * 4 + 4,
              let data = Data(base64Encoded: base64),
              !data.isEmpty
        else { return nil }
        return data
    }
}

/// A now-playing item as MediaRemote reports it: from any app, browsers included.
nonisolated struct AdapterTrack: Equatable, Sendable {
    /// The app that owns the item. For Safari this is `com.apple.Safari`, not the WebKit
    /// helper process that actually plays the media.
    let sourceBundleIdentifier: String
    let itemIdentifier: String?
    let title: String
    let artist: String
    let isPlaying: Bool
    /// Elapsed time as of `timestamp`. MediaRemote does not tick; the live position is
    /// extrapolated from these two and the rate.
    let elapsedAtTimestamp: TimeInterval?
    let timestamp: Date?
    let playbackRate: Double?
    let duration: TimeInterval?
    let artwork: Data?

    static let pausedExtrapolationLimit: TimeInterval = 1

    func elapsed(at date: Date) -> TimeInterval? {
        guard let elapsedAtTimestamp else { return nil }
        var elapsed = elapsedAtTimestamp
        // The rate, not `playing`, says whether the position is moving. On pause MediaRemote
        // sends `playing: false` alone and the frozen elapsed time and zero rate in the next
        // line; trusting `playing` there would snap the position back to its last timestamp.
        // A player that reports `playing` without any rate is playing at normal speed.
        let rate = playbackRate ?? (isPlaying ? 1 : 0)
        if rate > 0, let timestamp {
            var interval = max(date.timeIntervalSince(timestamp), 0)
            if !isPlaying {
                // Paused but the zero rate has not arrived yet. Keep moving only briefly, so a
                // line that never comes cannot leave a paused position running.
                interval = min(interval, Self.pausedExtrapolationLimit)
            }
            elapsed += interval * rate
        }
        if let duration {
            elapsed = min(elapsed, duration)
        }
        return max(elapsed, 0)
    }

    var player: NowPlayingStatus.Player {
        NowPlayingStatus.Player(bundleIdentifier: sourceBundleIdentifier)
    }

    /// Changes when the item changes and again when its artwork arrives, so the artwork view
    /// animates once per real change and never compares bytes.
    var artworkIdentity: String {
        [
            sourceBundleIdentifier,
            itemIdentifier ?? title,
            artwork.map { String($0.count) } ?? "none",
        ].joined(separator: "\u{1F}")
    }

    func nowPlayingStatus(at date: Date) -> NowPlayingStatus {
        NowPlayingStatus(
            player: player,
            title: title,
            artist: artist,
            isPlaying: isPlaying,
            elapsedPosition: elapsed(at: date),
            duration: duration,
            artwork: artwork,
            artworkIdentity: artwork == nil ? nil : artworkIdentity
        )
    }
}
