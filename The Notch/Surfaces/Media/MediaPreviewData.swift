import AppKit
import Foundation

@MainActor
enum MediaPreviewData {
    static func playingMonitor() -> NowPlayingMonitor {
        NowPlayingMonitor(
            previewStatus: NowPlayingStatus(
                player: .spotify,
                title: "Night Drive Through Jakarta",
                artist: "Glass Harbor",
                isPlaying: true,
                elapsedPosition: 104,
                duration: 306,
                artwork: placeholderArtwork()
            )
        )
    }

    static func pausedMonitor() -> NowPlayingMonitor {
        NowPlayingMonitor(
            previewStatus: NowPlayingStatus(
                player: .music,
                title: "After the Rain",
                artist: "Maya Bell",
                isPlaying: false,
                elapsedPosition: 141,
                duration: 278
            )
        )
    }

    static func longTitleMonitor() -> NowPlayingMonitor {
        NowPlayingMonitor(
            previewStatus: NowPlayingStatus(
                player: .spotify,
                title: "A Deliberately Long Song Title for Judging the Collapsed Shoulder",
                artist: "The Exceptionally Long Ensemble Name That Must Truncate Cleanly",
                isPlaying: true,
                elapsedPosition: 107,
                duration: 319,
                artwork: placeholderArtwork()
            )
        )
    }

    static func inactiveMonitor() -> NowPlayingMonitor {
        NowPlayingMonitor(previewStatus: .inactive)
    }

    private static func placeholderArtwork() -> Data? {
        let size = NSSize(width: 128, height: 128)
        let image = NSImage(size: size)

        // Broad, high-contrast bands make cropping, stretching, and rounded clipping obvious
        // without pretending this fixture is product artwork.
        image.lockFocus()
        NSColor(calibratedRed: 0.96, green: 0.35, blue: 0.22, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 128, height: 128).fill()
        NSColor(calibratedRed: 0.16, green: 0.72, blue: 0.82, alpha: 1).setFill()
        NSRect(x: 0, y: 42, width: 128, height: 44).fill()
        NSColor(calibratedRed: 0.94, green: 0.78, blue: 0.24, alpha: 1).setFill()
        NSRect(x: 70, y: 0, width: 58, height: 128).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
