import Combine
import Foundation

/// The scratchpad's pages: a few sheets of plain text, always there, never named or managed.
///
/// Saved as they are typed — there is no Save button anywhere — to `UserDefaults` under a key
/// `NotchSettings` does not own, so Restore defaults never touches what someone wrote. Writes are
/// coalesced: a keystroke re-encodes every page, and doing that on every character of a long note
/// is wasted work.
@MainActor
final class NotesStore: ObservableObject {
    /// Enough to keep two or three things apart without becoming a list to tidy.
    static let pageCount = 4
    private static let storageKey = "NotchNotePages"
    private static let selectionKey = "NotchNoteSelectedPage"
    private static let saveDelay: Duration = .milliseconds(400)

    @Published private(set) var pages: [String]
    @Published private(set) var selectedPage: Int

    private let defaults: UserDefaults?
    private var saveTask: Task<Void, Never>?

    /// `defaults: nil` keeps everything in memory, for previews and `FrameDump`.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        var loaded = defaults?.stringArray(forKey: Self.storageKey) ?? []
        loaded = Array(loaded.prefix(Self.pageCount))
        loaded += Array(repeating: "", count: Self.pageCount - loaded.count)
        pages = loaded
        selectedPage = min(max(defaults?.integer(forKey: Self.selectionKey) ?? 0, 0), Self.pageCount - 1)
    }

    var text: String { pages[selectedPage] }

    func select(_ page: Int) {
        guard pages.indices.contains(page), page != selectedPage else { return }
        selectedPage = page
        scheduleSave()
    }

    func updateText(_ text: String) {
        guard pages[selectedPage] != text else { return }
        pages[selectedPage] = text
        scheduleSave()
    }

    func clear() {
        updateText("")
    }

    /// Writes immediately. Called when the app quits so the last half second of typing is kept.
    func flush() {
        saveTask?.cancel()
        save()
    }

    private func scheduleSave() {
        guard defaults != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    private func save() {
        guard let defaults else { return }
        defaults.set(pages, forKey: Self.storageKey)
        defaults.set(selectedPage, forKey: Self.selectionKey)
    }
}
