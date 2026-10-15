import CryptoKit
import Foundation

/// Covers seen for browser items, kept on disk so a restart does not lose them.
///
/// A browser sends a tab's cover only the first time it plays; resuming it later, or starting
/// The Notch while it plays, brings the title and no artwork. `AdapterSnapshot` remembers covers
/// for the life of one stream; this keeps them across launches. Files live in the app's caches
/// folder, named by a hash of the item (app, title, artist), and only the most recent are kept.
nonisolated final class ArtworkStore: @unchecked Sendable {
    /// Browser covers run up to ~1.6 MB, so this bounds the folder to a few tens of MB.
    static let maximumFileCount = 24

    private let directory: URL?
    private let fileManager = FileManager.default
    // Callers serialise access: `MediaRemoteAdapterStream` uses it only from its own queue.

    init(directory: URL? = ArtworkStore.defaultDirectory) {
        self.directory = directory
        if let directory {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    static var defaultDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "The Notch"
        return caches.appending(path: bundle).appending(path: "MediaArtwork")
    }

    func artwork(for key: String) -> Data? {
        guard let url = fileURL(for: key),
              let data = try? Data(contentsOf: url),
              !data.isEmpty,
              data.count <= AdapterSnapshot.maximumArtworkByteCount
        else { return nil }
        // Touch it, so pruning keeps what is still being played.
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    func save(_ artwork: Data, for key: String) {
        guard let url = fileURL(for: key),
              artwork.count <= AdapterSnapshot.maximumArtworkByteCount
        else { return }
        if let existing = try? Data(contentsOf: url), existing == artwork { return }
        guard (try? artwork.write(to: url, options: .atomic)) != nil else { return }
        prune()
    }

    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: name)
    }

    private func prune() {
        guard let directory,
              let files = try? fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey]
              ),
              files.count > Self.maximumFileCount
        else { return }
        let dated = files.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast)
        }
        for (url, _) in dated.sorted(by: { $0.1 < $1.1 }).dropLast(Self.maximumFileCount) {
            try? fileManager.removeItem(at: url)
        }
    }
}
