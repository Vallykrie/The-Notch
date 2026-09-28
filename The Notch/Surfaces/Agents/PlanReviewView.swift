import SwiftUI

/// Temporary presentation model until plans are published by AgentSessionStore.
/// TODO: replace with a store-backed plan API.
nonisolated struct PlanReviewRequest: Identifiable, Sendable {
    let id: UUID
    let kind: AgentKind
    let projectDisplayName: String
    let markdown: String

    init(
        id: UUID = UUID(),
        kind: AgentKind,
        projectDisplayName: String,
        markdown: String
    ) {
        self.id = id
        self.kind = kind
        self.projectDisplayName = projectDisplayName
        self.markdown = markdown
    }
}

@MainActor
struct PlanReviewView: View {
    let request: PlanReviewRequest
    let onSend: (String) -> Void
    let onApprove: () -> Void

    @State private var feedback = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Metrics.collapsedContentSpacing) {
            HStack(spacing: Theme.Metrics.expandedContentSpacing) {
                PixelGlyphView(glyph: request.kind.glyph, side: Theme.Metrics.glyphExpandedSize)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .accessibilityLabel(request.kind.displayName)

                Text(request.projectDisplayName)
                    .font(Theme.Text.headline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: Theme.Metrics.collapsedContentSpacing)

                Text("PLAN")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            ScrollView {
                Text(renderedPlan)
                    .font(Theme.Text.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(Theme.Metrics.Agents.planLineLimit)
                    .textSelection(.enabled)
            }
            .scrollIndicators(.hidden)

            HStack(alignment: .bottom, spacing: Theme.Metrics.collapsedContentSpacing) {
                TextField("Suggest a change…", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...2)

                Button("Send") {
                    let message = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !message.isEmpty else { return }
                    onSend(message)
                    feedback = ""
                }
                .buttonStyle(.notch)
                .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Approve") {
                    onApprove()
                }
                .buttonStyle(.notch)
                .tint(Theme.Colors.Status.working)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
        .padding(.vertical, Theme.Metrics.expandedVerticalPadding)
    }

    private var renderedPlan: AttributedString {
        (try? AttributedString(markdown: request.markdown)) ?? AttributedString(request.markdown)
    }
}
