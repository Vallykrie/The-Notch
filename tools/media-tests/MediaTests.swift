import Foundation

/// Checks for the MediaRemote payload path: diff merging, source resolution, artwork decoding
/// and elapsed-time extrapolation. Fixture lines mirror real `stream --micros` output, with
/// placeholder titles. Never spawns perl.
@main
struct MediaTests {
    static var failures = 0

    static func check(_ condition: Bool, _ name: String) {
        print("\(condition ? "PASS" : "FAIL"): \(name)")
        if !condition { failures += 1 }
    }

    static func line(_ json: String) -> Data {
        Data(json.utf8)
    }

    static func main() {
        snapshotMerging()
        sourceResolution()
        artwork()
        elapsedTime()
        statusMapping()
        lyricsQueries()

        if failures > 0 {
            print("\(failures) check(s) failed")
            exit(1)
        }
        print("all media checks passed")
    }

    static func snapshotMerging() {
        var snapshot = AdapterSnapshot()
        check(snapshot.apply(line: line(#"{"type":"data","diff":false,"payload":{}}"#)),
              "an empty full snapshot parses")
        check(snapshot.track == nil, "an empty snapshot is nothing playing")

        snapshot.apply(line: line(#"""
        {"type":"data","diff":false,"payload":{"bundleIdentifier":"com.google.Chrome","title":"Track A","artist":"Artist A","playing":true,"playbackRate":1,"elapsedTimeMicros":5000000,"timestampEpochMicros":1700000000000000,"durationMicros":200000000,"contentItemIdentifier":"item-a"}}
        """#))
        let first = snapshot.track
        check(first?.title == "Track A" && first?.artist == "Artist A", "a full snapshot maps title and artist")
        check(first?.duration == 200 && first?.elapsedAtTimestamp == 5, "micros become seconds")
        check(first?.isPlaying == true, "playing is read as a bool")

        snapshot.apply(line: line(#"{"type":"data","diff":true,"payload":{"playing":false}}"#))
        check(snapshot.track?.isPlaying == false, "a diff changes only the keys it carries")
        check(snapshot.track?.title == "Track A", "a diff keeps the keys it does not mention")

        snapshot.apply(line: line(#"{"type":"data","diff":true,"payload":{"artist":null}}"#))
        check(snapshot.track?.artist == "", "null in a diff removes the key")

        check(!snapshot.apply(line: line("not json")), "a malformed line is rejected")
        check(snapshot.track?.title == "Track A", "a malformed line leaves the snapshot untouched")

        snapshot.apply(line: line(#"{"type":"data","diff":false,"payload":{}}"#))
        check(snapshot.track == nil, "an empty full snapshot clears the item")

        var untitled = AdapterSnapshot()
        untitled.apply(line: line(#"{"diff":false,"payload":{"bundleIdentifier":"com.example.App","title":"  "}}"#))
        check(untitled.track == nil, "a blank title is not an item")
    }

    static func sourceResolution() {
        var safari = AdapterSnapshot()
        safari.apply(line: line(#"""
        {"diff":false,"payload":{"bundleIdentifier":"com.apple.WebKit.GPU","parentApplicationBundleIdentifier":"com.apple.Safari","title":"Track B","playing":true}}
        """#))
        check(safari.track?.sourceBundleIdentifier == "com.apple.Safari",
              "Safari is named by its parent, not the WebKit helper")

        check(NowPlayingStatus.Player(bundleIdentifier: "com.spotify.client") == .spotify,
              "Spotify maps to the Spotify player")
        check(NowPlayingStatus.Player(bundleIdentifier: "com.apple.Music") == .music,
              "Music maps to the Music player")
        check(NowPlayingStatus.Player(bundleIdentifier: "com.brave.Browser")
                  == .app(bundleIdentifier: "com.brave.Browser"),
              "any other app is kept by bundle identifier")
    }

    static func artwork() {
        let bytes = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10])
        var snapshot = AdapterSnapshot()
        snapshot.apply(line: line(#"{"diff":false,"payload":{"bundleIdentifier":"com.google.Chrome","title":"Track C","contentItemIdentifier":"item-c"}}"#))
        check(snapshot.track?.artwork == nil, "metadata can arrive before artwork")
        let noArtworkIdentity = snapshot.track?.artworkIdentity

        snapshot.apply(line: line(#"{"diff":true,"payload":{"artworkData":"\#(bytes.base64EncodedString())"}}"#))
        check(snapshot.track?.artwork == bytes, "artwork is decoded from base64")
        check(snapshot.track?.artworkIdentity != noArtworkIdentity, "the artwork identity changes when artwork lands")

        snapshot.apply(line: line(#"{"diff":true,"payload":{"elapsedTimeMicros":1000000}}"#))
        check(snapshot.track?.artwork == bytes, "artwork survives diffs that do not mention it")

        snapshot.apply(line: line(#"{"diff":true,"payload":{"artworkData":"%%% not base64"}}"#))
        check(snapshot.track?.artwork == nil, "invalid base64 is no artwork, not a crash")

        snapshot.apply(line: line(#"{"diff":true,"payload":{"artworkData":null}}"#))
        check(snapshot.track?.artwork == nil, "removed artwork is gone")
    }

    static func elapsedTime() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        func track(playing: Bool, rate: Double?, elapsed: TimeInterval = 10) -> AdapterTrack {
            AdapterTrack(
                sourceBundleIdentifier: "com.google.Chrome", itemIdentifier: "item",
                title: "Track", artist: "Artist", isPlaying: playing,
                elapsedAtTimestamp: elapsed, timestamp: timestamp,
                playbackRate: rate, duration: 100, artwork: nil
            )
        }

        check(track(playing: true, rate: 1).elapsed(at: timestamp.addingTimeInterval(5)) == 15,
              "playing at rate 1 moves with the clock")
        check(track(playing: true, rate: 2).elapsed(at: timestamp.addingTimeInterval(5)) == 20,
              "the rate scales the extrapolation")
        check(track(playing: true, rate: nil).elapsed(at: timestamp.addingTimeInterval(5)) == 15,
              "playing without a rate assumes normal speed")
        check(track(playing: false, rate: 0).elapsed(at: timestamp.addingTimeInterval(5)) == 10,
              "a paused position does not move")
        check(track(playing: false, rate: 1).elapsed(at: timestamp.addingTimeInterval(0.5)) == 10.5,
              "pausing before the zero rate arrives keeps the position, not its old timestamp")
        check(track(playing: false, rate: 1).elapsed(at: timestamp.addingTimeInterval(30)) == 11,
              "a paused position never runs on for long")
        check(track(playing: true, rate: 1, elapsed: 98).elapsed(at: timestamp.addingTimeInterval(10)) == 100,
              "the position is clamped to the duration")
        check(track(playing: true, rate: 1).elapsed(at: timestamp.addingTimeInterval(-3)) == 10,
              "a clock behind the timestamp never moves the position backwards")
    }

    static func statusMapping() {
        let track = AdapterTrack(
            sourceBundleIdentifier: "com.apple.Safari", itemIdentifier: "item-d",
            title: "Track D", artist: "Artist D", isPlaying: true,
            elapsedAtTimestamp: 1, timestamp: Date(), playbackRate: 1,
            duration: 60, artwork: Data([1, 2, 3])
        )
        let status = track.nowPlayingStatus(at: Date())
        check(status.isActive && status.player == .app(bundleIdentifier: "com.apple.Safari"),
              "a browser item becomes an active status for that app")
        check(status.title == "Track D" && status.duration == 60, "the status carries the metadata")
        check(status.artworkIdentity == track.artworkIdentity, "the status uses the item's artwork identity")
    }

    static func lyricsQueries() {
        typealias Query = LyricsProvider.Query
        let queen = LyricsProvider.searchQueries(
            title: "Queen - All Dead, All Dead - At Last, the Video!", artist: "Queen"
        )
        check(queen.first == Query(title: "Queen - All Dead, All Dead - At Last, the Video!", artist: "Queen"),
              "the full title is tried first")
        check(queen.contains(Query(title: "All Dead, All Dead", artist: "Queen")),
              "a leading artist is removed before the title is cut at a dash")
        check(!queen.contains { $0.title == "Queen" },
              "a video title never becomes a search for a song named after the artist")

        let aha = LyricsProvider.searchQueries(
            title: "a-ha - Take On Me (Official Video) [4K]", artist: "a-ha"
        )
        check(aha.contains(Query(title: "Take On Me", artist: "a-ha")),
              "video decorations in brackets are removed")

        let spotify = LyricsProvider.searchQueries(
            title: "I See the Light - From \"Tangled\" / Soundtrack Version", artist: "Mandy Moore"
        )
        check(spotify.prefix(2) == [
            Query(title: "I See the Light - From \"Tangled\" / Soundtrack Version", artist: "Mandy Moore"),
            Query(title: "I See the Light", artist: "Mandy Moore"),
        ], "a player's decorated title still falls back to its bare name second")

        let channel = LyricsProvider.searchQueries(
            title: "Rick Astley - Never Gonna Give You Up (Official Video)", artist: "SomeChannel"
        )
        check(channel.contains(Query(title: "Never Gonna Give You Up", artist: "Rick Astley")),
              "an upload by another channel is searched as Artist - Title")

        let topic = LyricsProvider.searchQueries(title: "Bohemian Rhapsody", artist: "Queen - Topic")
        check(topic.first == Query(title: "Bohemian Rhapsody", artist: "Queen"),
              "a YouTube Topic channel is searched as the artist")

        let plain = LyricsProvider.searchQueries(title: "Yesterday", artist: "The Beatles")
        check(plain == [Query(title: "Yesterday", artist: "The Beatles")],
              "an undecorated title is searched once")
    }
}
