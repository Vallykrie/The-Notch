import Combine
import Foundation

/// Lyrics for whatever is playing, shared by the expanded media panel and the collapsed notch.
///
/// It lived as view state inside `MediaExpandedView` until the collapsed notch needed it too:
/// the line being sung is shown across the camera housing while lyrics are on, and the notch
/// is drawn by a different view tree that cannot reach the panel's `@State`.
///
/// Nothing is fetched while lyrics are off. Turning them on is what sends the track's title
/// and artist to the lyrics service — see `LyricsProvider`.
@MainActor
final class LyricsController: ObservableObject {
    /// The user's lyrics toggle. Remembered for the session, not across launches: opening the
    /// app to a panel that is already sending track names somewhere would be a surprise.
    @Published var isEnabled = false {
        didSet { if isEnabled != oldValue { reconcile() } }
    }
    /// The lookup for the current track: `nil` while one is in flight or lyrics are off.
    @Published private(set) var lookup: LyricsLookup? {
        didSet { updateTicker() }
    }
    /// The synced line being sung, or `nil` before the first line (and when there are no
    /// synced lyrics). Published, rather than worked out by each view from the clock, so the
    /// panel's reel, the notch's text and the notch's *width* all change on the same tick —
    /// the width depends on the line, and a silhouette resizing a frame after its text would
    /// visibly clip the new line first.
    @Published private(set) var currentLineIndex: Int?

    private let nowPlaying: NowPlayingMonitor
    private var trackKey: String?
    private var task: Task<Void, Never>?
    private var anchor: (position: TimeInterval, date: Date)?
    private var observation: AnyCancellable?
    /// Set by `seedPreview`, so a preview never reaches the network.
    private var isSeeded = false
    private var ticker: Timer?

    init(nowPlaying: NowPlayingMonitor) {
        self.nowPlaying = nowPlaying
        observation = nowPlaying.$status.sink { [weak self] status in
            // `$status` delivers from `willSet`, so read the new value from the argument.
            self?.statusWillChange(to: status)
        }
    }

    /// The synced lyrics, when lyrics are on and the current track has them.
    var synced: Lyrics? {
        guard isEnabled, case let .found(lyrics) = lookup, lyrics.isSynced else { return nil }
        return lyrics
    }

    /// Whether the collapsed notch should carry the sung line: lyrics on, synced lyrics found,
    /// and the track actually playing. A paused track keeps its normal shoulders.
    var showsOnNotch: Bool {
        synced != nil && nowPlaying.status.isPlaying
    }

    /// The line being sung, as text.
    var currentLine: String? {
        guard let synced, let currentLineIndex else { return nil }
        return synced.synced[currentLineIndex].text
    }

    /// Where playback is at `date`: the last position the player reported, carried forward
    /// while playing. The player is polled every two seconds; a reel that only moved on each
    /// poll would step late by up to that much.
    func position(at date: Date) -> TimeInterval {
        guard let anchor else { return 0 }
        let elapsed = nowPlaying.status.isPlaying ? date.timeIntervalSince(anchor.date) : 0
        let position = anchor.position + elapsed
        return min(position, nowPlaying.status.duration ?? position)
    }

    // MARK: Tracking the player

    private func statusWillChange(to status: NowPlayingStatus) {
        if status.elapsedPosition != nowPlaying.status.elapsedPosition || anchor == nil {
            anchor = status.elapsedPosition.map { ($0, Date()) }
        }
        if status.isPlaying != nowPlaying.status.isPlaying {
            DispatchQueue.main.async { [weak self] in self?.updateTicker() }
        }
        let key = status.isActive ? "\(status.title)\u{1F}\(status.artist)" : nil
        if key != trackKey {
            trackKey = key
            // Deferred a turn so `nowPlaying.status` already holds the new track when the
            // lookup reads its duration.
            DispatchQueue.main.async { [weak self] in self?.reconcile() }
        }
    }

    /// Looks the current track up again, skipping the cache — the panel's "Try again".
    func retry() {
        reconcile(ignoringCache: true)
    }

    /// Fetches lyrics for the current track. A failure is retried quietly before it is shown:
    /// the service answers in well under a second almost always, and a single dropped request
    /// is far more often a blip than an outage — showing "couldn't reach" for it read as the
    /// feature being broken while the song's lyrics were sitting right there in Spotify.
    private func reconcile(ignoringCache: Bool = false) {
        task?.cancel()
        lookup = nil
        guard isEnabled, trackKey != nil, !isSeeded else { return }
        let status = nowPlaying.status
        task = Task { [weak self] in
            let delays = [0] + Theme.Metrics.MediaPanel.lyricsRetryDelays
            for (attempt, delay) in delays.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled else { return }
                let result = await LyricsProvider.shared.lyrics(
                    title: status.title,
                    artist: status.artist,
                    duration: status.duration,
                    ignoringCache: ignoringCache && attempt == 0
                )
                guard !Task.isCancelled else { return }
                if result != .failed || attempt == delays.count - 1 {
                    self?.lookup = result
                    return
                }
            }
        }
    }

    // MARK: The line clock

    /// Ticks only while there is a line to follow: lyrics on, synced lyrics loaded, and the
    /// track playing. A paused track has nothing to advance.
    private func updateTicker() {
        tick()
        let needsTicker = synced != nil && nowPlaying.status.isPlaying
        if needsTicker, ticker == nil {
            let timer = Timer(timeInterval: Theme.Metrics.MediaPanel.lyricsTick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        } else if !needsTicker {
            ticker?.invalidate()
            ticker = nil
        }
    }

    private func tick() {
        let index = synced?.lineIndex(at: position(at: Date()))
        if index != currentLineIndex { currentLineIndex = index }
    }

    #if DEBUG
    /// Previews and `FrameDump` only: lyrics already loaded, no network.
    func seedPreview(_ lyrics: Lyrics, position: TimeInterval) {
        isSeeded = true
        isEnabled = true
        task?.cancel()
        anchor = (position, Date())
        lookup = .found(lyrics)
        tick()
    }
    #endif
}
