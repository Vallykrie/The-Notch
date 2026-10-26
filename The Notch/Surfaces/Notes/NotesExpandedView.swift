import AppKit
import SwiftUI

/// The notes panel: a scratchpad for writing something down without opening another app — a
/// prompt before an agent sees it, a reply being drafted, a number to keep for a minute.
///
/// Concept A from `docs/design/notes-ui-v1.html`. One sheet with the cursor already in it, and
/// four pages for when two things are being juggled. Copy (⌘↩) puts the page on the clipboard
/// and closes the notch, so the next keystroke can be ⌘V wherever the user was.
///
/// While the editor is being typed into the panel is pinned open, the way settings is: a pointer
/// drifting off a strip at the top of the screen must not throw away the sentence being written.
/// Escape, Copy, or clicking into another app releases it.
@MainActor
struct NotesExpandedView: View {
    @ObservedObject var notes: NotesStore
    var onEditingChanged: (Bool) -> Void = { _ in }
    /// Closes the notch after a copy, so keyboard focus goes back to the app the user was in
    /// instead of staying on a panel with nothing left to type into.
    var onCopied: () -> Void = {}

    @Environment(\.rendersOffscreen) private var rendersOffscreen
    @FocusState private var editorFocused: Bool
    @State private var windowIsKey = false

    private typealias Metrics = Theme.Metrics.Notes

    /// Keystrokes would land in the editor: it has focus and the panel is the key window.
    private var isEditing: Bool { editorFocused && windowIsKey }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            editor
            footer
                .frame(height: Metrics.footerHeight)
        }
        .foregroundStyle(Theme.Colors.textPrimary)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.bottom, Theme.Metrics.expandedVerticalPadding)
        .onAppear {
            windowIsKey = NSApp.keyWindow is NotchWindow
            editorFocused = true
        }
        .onDisappear { onEditingChanged(false) }
        // Focus alone is not typing: the editor takes focus as soon as the tab shows, and a
        // panel opened by hover is not key, so nothing typed would reach it. Pinning on focus
        // alone would hold open a notch the user only glanced at.
        .onChange(of: isEditing) { _, editing in onEditingChanged(editing) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object is NotchWindow { windowIsKey = true }
        }
        // Clicking into another app takes key status from the panel without SwiftUI dropping
        // focus, which would leave the panel pinned open over whatever the user went back to.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            if note.object is NotchWindow { windowIsKey = false }
        }
        .onExitCommand { editorFocused = false }
    }

    // MARK: Editor

    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if rendersOffscreen {
                // `ImageRenderer` draws an AppKit-backed text view as a placeholder, so the frame
                // dump gets the text the editor would show, on the editor's inset.
                Text(notes.text)
                    .font(Theme.Text.body)
                    .padding(.leading, Metrics.editorTextInset)
            } else {
                textEditor
            }

            if notes.text.isEmpty {
                Text("Type anything…")
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.leading, Metrics.editorTextInset)
                    .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var textEditor: some View {
        TextEditor(text: Binding(
            get: { notes.text },
            set: { notes.updateText($0) }
        ))
        .font(Theme.Text.body)
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .textEditorStyle(.plain)
        .tint(Theme.Colors.notesAccent)
        .focused($editorFocused)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Metrics.chipSpacing * 2) {
            HStack(spacing: Metrics.chipSpacing) {
                ForEach(0..<NotesStore.pageCount, id: \.self) { page in
                    pageButton(page)
                }
            }

            Text(countLabel)
                .font(Theme.Text.micro)
                .foregroundStyle(Theme.Colors.textTertiary)
                .lineLimit(1)

            Spacer(minLength: .zero)

            Button("Clear") {
                notes.clear()
                editorFocused = true
            }
            .buttonStyle(NotchButtonStyle(role: .tertiary, size: .compact))
            .disabled(notes.text.isEmpty)

            Button(action: copy) {
                Text("Copy  ⌘↩")
            }
            .buttonStyle(NotchButtonStyle(role: .primary(tint: Theme.Colors.textPrimary), size: .compact))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(notes.text.isEmpty)
        }
    }

    private func pageButton(_ page: Int) -> some View {
        let isSelected = page == notes.selectedPage
        let hasText = !notes.pages[page].isEmpty
        return Button {
            notes.select(page)
            editorFocused = true
        } label: {
            Text("\(page + 1)")
                .font(Theme.Text.micro)
                .foregroundStyle(
                    isSelected ? Theme.Colors.textPrimary
                        : hasText ? Theme.Colors.textSecondary
                        : Theme.Colors.textTertiary
                )
                .frame(width: Metrics.pageButtonSize, height: Metrics.pageButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.chipCornerRadius, style: .continuous)
                        .fill(Theme.Colors.textPrimary.opacity(
                            isSelected ? Metrics.selectedPageFillOpacity : Metrics.pageFillOpacity
                        ))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character("\(page + 1)")), modifiers: .command)
        .help("Page \(page + 1) (⌘\(page + 1))")
    }

    private var countLabel: String {
        let count = notes.text.count
        return count == 0 ? "Saved as you type" : "\(count) chars · saved"
    }

    private func copy() {
        guard !notes.text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(notes.text, forType: .string)
        editorFocused = false
        onCopied()
    }
}
