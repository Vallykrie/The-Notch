import SwiftUI

@MainActor
enum AgentsPreviewData {
    /// A real `tool_input`, as an object — not as a string that happens to contain JSON.
    ///
    /// The preview used to pass the latter, which is why nobody saw what the approval card was
    /// actually rendering: a string is echoed verbatim, so the preview showed prose while the
    /// running app showed `{"command":"…","description":"…"}`. Previews that do not carry the
    /// shape the app receives cannot catch a bug in how that shape is presented.
    static let longToolInput = JSONValue.object([
        // Deliberately past `summaryLineLimit`: the clamp is the thing being verified, and a
        // command that happens to fit proves nothing about the case that used to hang the
        // buttons off the bottom curve.
        "command": .string(
            "xcodebuild -project 'The Notch.xcodeproj' -scheme 'The Notch' "
                + "-configuration Debug -destination 'platform=macOS,arch=arm64' "
                + "CODE_SIGNING_ALLOWED=NO build test 2>&1 | grep -E 'error:|warning:' "
                + "| sort -u | tail -40"
        ),
        "description": .string(
            "Compile the complete macOS target and inspect strict-concurrency diagnostics "
                + "across every source file before reporting completion. This deliberately "
                + "continues with enough realistic detail to verify that the approval card "
                + "clamps a long line without pushing its buttons past the bottom curve."
        ),
        "timeout": .number(600_000),
    ])

    /// The payload from the screenshot that started this: `AskUserQuestion`, whose input is
    /// nested schema. The card must find the question inside it.
    static let questionToolInput = JSONValue.object([
        "questions": .array([
            .object([
                "header": .string("Mascot path"),
                "multiSelect": .bool(false),
                "question": .string("Which mascot should the collapsed shoulder draw?"),
                "options": .array([
                    .object([
                        "label": .string("Keep the robot"),
                        "description": .string("The 16x16 sprite already in the bundle."),
                    ]),
                    .object([
                        "label": .string("Draw a new one"),
                        "description": .string("Costs a pass over the pixel grid."),
                    ]),
                ]),
            ]),
        ]),
    ])

    static let plan = PlanReviewRequest(
        kind: .claudeCode,
        projectDisplayName: "The Notch",
        markdown: """
        ## Implementation plan
        1. Add the compact session status surface.
        2. Prioritize blocking permission requests.
        3. Verify keyboard approval and denial paths.

        **Validation:** Build the macOS 14 target with strict concurrency enabled.
        """
    )

    static func emptyStore() -> AgentSessionStore {
        AgentSessionStore()
    }

    /// Two agents hooked up, one that could not be, and the rest not installed — the mix the
    /// empty state has to read well with.
    static func detectedIntegrations() -> AgentIntegrationManager {
        let manager = AgentIntegrationManager()
        #if DEBUG
        manager.seedPreviewStatuses([
            AgentIntegrationStatus(provider: .claude, installed: true, configured: true, error: nil),
            AgentIntegrationStatus(provider: .codex, installed: true, configured: true, error: nil),
            AgentIntegrationStatus(provider: .gemini, installed: true, configured: false, error: "Preview error"),
            AgentIntegrationStatus(provider: .cursor, installed: false, configured: false, error: nil),
        ])
        #endif
        return manager
    }

    static func workingStore(now: Date = .now) -> AgentSessionStore {
        let store = AgentSessionStore()
        store.handle(
            request(
                id: "codex-notch",
                source: "codex",
                cwd: "/Users/you/code/The Notch",
                event: .preToolUse,
                toolName: "xcodebuild",
                totalTokens: 18_420,
                costUSD: 0.42
            ),
            at: now.addingTimeInterval(-12)
        )
        return store
    }

    static func concurrentStore(now: Date = .now) -> AgentSessionStore {
        let store = workingStore(now: now)
        store.handle(
            request(
                id: "claude-api",
                source: "claude-code",
                cwd: "/Users/you/code/Bridge API",
                event: .notification,
                totalTokens: 61_905,
                costUSD: 1.87
            ),
            at: now.addingTimeInterval(-48)
        )
        store.handle(
            request(
                id: "codex-docs",
                source: "codex",
                cwd: "/Users/you/docs/Release Notes",
                event: .sessionStart
            ),
            at: now.addingTimeInterval(-82)
        )
        store.handle(
            request(
                id: "claude-done",
                source: "claude-code",
                cwd: "/Users/you/code/Menu Bar Tools",
                event: .stop,
                totalTokens: 9_712,
                costUSD: 0.19
            ),
            at: now.addingTimeInterval(-130)
        )
        return store
    }

    /// Two sessions in two *different* states, which no other store here produces.
    ///
    /// Every other multi-session store converges on one or two statuses, which was fine while
    /// the mark was a coloured dot and is not fine now that each state has its own motion: the
    /// thing worth looking at in the expanded panel is different animations running beside each
    /// other, and a panel full of one animation cannot show that.
    ///
    /// **Two, and this is a ceiling rather than a preference.** Four rows (`concurrentStore`)
    /// overflow the 190pt panel, `ViewThatFits` takes the `ScrollView` branch, and
    /// `ImageRenderer` draws a `ScrollView` as empty — which is why `scenario-expanded-agents`
    /// has always dumped as a blank panel. Three was tried here and dumped blank for the same
    /// reason; the list fits exactly two rows under the header. Adding a third session to this
    /// store does not make the dump busier, it makes it empty.
    ///
    /// `runningTool` and `compacting` specifically, because a chase around a ring and two bars
    /// closing on each other are the least confusable pair in the set.
    static func mixedStatusStore(now: Date = .now) -> AgentSessionStore {
        let store = AgentSessionStore()
        store.handle(
            request(
                id: "codex-notch",
                source: "codex",
                cwd: "/Users/you/code/The Notch",
                event: .preToolUse,
                toolName: "xcodebuild",
                totalTokens: 18_420,
                costUSD: 0.42
            ),
            at: now.addingTimeInterval(-12)
        )
        store.handle(
            request(
                id: "claude-api",
                source: "claude-code",
                cwd: "/Users/you/code/Bridge API",
                event: .preCompact,
                totalTokens: 128_400,
                costUSD: 2.14
            ),
            at: now.addingTimeInterval(-48)
        )
        return store
    }

    static func approvalStore(now: Date = .now) -> AgentSessionStore {
        let store = concurrentStore(now: now)
        store.registerPermissionNotice(
            request(
                id: "claude-approval",
                source: "claude-code",
                cwd: "/Users/you/code/The Notch",
                event: .permissionRequest,
                toolName: "Bash",
                toolInput: longToolInput
            ),
            at: now.addingTimeInterval(-154)
        )
        return store
    }

    /// The other end of the approval card's range: a short tool name, a nested input, and an
    /// agent that has been blocked long enough for the elapsed label to have rolled over.
    static func questionApprovalStore(now: Date = .now) -> AgentSessionStore {
        let store = AgentSessionStore()
        store.registerPermissionNotice(
            request(
                id: "claude-question",
                source: "claude-code",
                cwd: "/Users/you/code/The Notch",
                event: .permissionRequest,
                toolName: "AskUserQuestion",
                toolInput: questionToolInput
            ),
            at: now.addingTimeInterval(-1_267)
        )
        return store
    }

    static func doneStore(now: Date = .now) -> AgentSessionStore {
        let store = AgentSessionStore()
        store.handle(
            request(
                id: "codex-finished",
                source: "codex",
                cwd: "/Users/you/code/The Notch",
                event: .stop,
                totalTokens: 32_880,
                costUSD: 0.73
            ),
            at: now.addingTimeInterval(-35)
        )
        return store
    }

    /// One session that has delegated: a parent mid-turn with two subagents under it, one of
    /// them already finished.
    ///
    /// The scenario that used to be indistinguishable from four separate agents. It is here
    /// rather than folded into `concurrentStore` because the thing worth looking at is the
    /// *indent* — a child row that has drifted out from under its parent's text, or a mark that
    /// has grown until it competes with the session's own, is only visible against a parent.
    static func subagentStore(now: Date = .now) -> AgentSessionStore {
        let store = AgentSessionStore()
        store.handle(
            request(
                id: "claude-notch",
                source: "claude-code",
                cwd: "/Users/you/code/The Notch",
                event: .userPromptSubmit
            ),
            at: now.addingTimeInterval(-64)
        )
        store.handle(
            request(
                id: "claude-notch",
                source: "claude-code",
                cwd: "/Users/you/code/The Notch",
                event: .preToolUse,
                toolName: "Task",
                totalTokens: 168_500
            ),
            at: now.addingTimeInterval(-60)
        )
        store.handle(
            request(
                id: "claude-notch",
                source: "claude-code",
                cwd: "/Users/you/code/The Notch",
                event: .preToolUse,
                toolName: "Grep",
                agentID: "a1",
                agentType: "Explore"
            ),
            at: now.addingTimeInterval(-18)
        )
        store.handle(
            request(
                id: "claude-notch",
                source: "claude-code",
                cwd: "/Users/you/code/The Notch",
                event: .subagentStop,
                agentID: "a2",
                agentType: "general-purpose"
            ),
            at: now.addingTimeInterval(-6)
        )
        return store
    }

    static func request(
        id: String,
        source: String,
        cwd: String,
        event: EventName,
        toolName: String? = nil,
        toolInput: JSONValue? = nil,
        totalTokens: Int64? = nil,
        costUSD: Double? = nil,
        agentID: String? = nil,
        agentType: String? = nil
    ) -> HookRequest {
        var payload: [String: JSONValue] = [:]
        if let toolName { payload["tool_name"] = .string(toolName) }
        if let toolInput { payload["tool_input"] = toolInput }
        if let totalTokens { payload["total_tokens"] = .number(Double(totalTokens)) }
        if let costUSD { payload["cost_usd"] = .number(costUSD) }
        // Exactly what a subagent's event carries on the wire: the parent's session id, plus
        // an agent id and type of its own.
        if let agentID { payload["agent_id"] = .string(agentID) }
        if let agentType { payload["agent_type"] = .string(agentType) }

        return HookRequest(
            id: UUID(),
            eventName: event,
            source: source,
            cwd: cwd,
            threadName: id,
            timeout: nil,
            payload: payload
        )
    }
}

#Preview("Status indicators") {
    HStack(spacing: Theme.Metrics.expandedContentSpacing) {
        ForEach(
            [
                SessionStatus.working,
                .waitingForInput,
                .needsApproval,
                .done,
                .idle,
            ],
            id: \.rawValue
        ) { status in
            StatusIndicator(status: status, size: Theme.Metrics.Agents.activityGlyphSize)
        }
    }
    .padding(Theme.Metrics.expandedHorizontalPadding)
    .background(.black)
}

#Preview("Collapsed — no sessions") {
    AgentsCollapsedView(store: AgentsPreviewData.emptyStore())
        .frame(
            width: Theme.Metrics.fauxNotchSize.width,
            height: Theme.Metrics.fauxNotchSize.height
        )
        .background(.black)
}

#Preview("Collapsed — working") {
    AgentsCollapsedView(store: AgentsPreviewData.workingStore())
        .frame(
            width: Theme.Metrics.fauxNotchSize.width,
            height: Theme.Metrics.fauxNotchSize.height
        )
        .background(.black)
}

#Preview("Expanded — no sessions") {
    @Previewable @Namespace var namespace
    AgentsExpandedView(store: AgentsPreviewData.emptyStore(), integrations: AgentsPreviewData.detectedIntegrations(), namespace: namespace)
        .frame(
            width: Theme.Metrics.expandedNotchSize.width,
            height: Theme.Metrics.expandedNotchSize.height
        )
        .background(.black)
}

#Preview("Expanded — concurrent sessions") {
    @Previewable @Namespace var namespace
    AgentsExpandedView(store: AgentsPreviewData.concurrentStore(), integrations: AgentIntegrationManager(), namespace: namespace)
        .frame(
            width: Theme.Metrics.expandedNotchSize.width,
            height: Theme.Metrics.expandedNotchSize.height
        )
        .background(.black)
}

#Preview("Expanded — approval priority") {
    @Previewable @Namespace var namespace
    AgentsExpandedView(store: AgentsPreviewData.approvalStore(), integrations: AgentIntegrationManager(), namespace: namespace)
        .frame(
            width: Theme.Metrics.expandedNotchSize.width,
            height: Theme.Metrics.expandedNotchSize.height
        )
        .background(.black)
}

#Preview("Session row — done") {
    @Previewable @Namespace var namespace
    SessionRowView(
        session: AgentsPreviewData.doneStore().sessions[0],
        namespace: namespace
    )
    .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
    .background(.black)
}

#Preview("Approval — long command") {
    @Previewable @Namespace var namespace
    let store = AgentsPreviewData.approvalStore()
    ApprovalCardView(
        store: store,
        approval: store.pendingApprovals[0],
        namespace: namespace
    )
    .padding(.horizontal, Theme.Metrics.expandedHorizontalPadding)
    .padding(.vertical, Theme.Metrics.expandedVerticalPadding)
    .frame(
        width: Theme.Metrics.expandedNotchSize.width,
        height: Theme.Metrics.expandedNotchSize.height
    )
    .background(.black)
}

#Preview("Approval — nested question input") {
    @Previewable @Namespace var namespace
    AgentsExpandedView(store: AgentsPreviewData.questionApprovalStore(), integrations: AgentIntegrationManager(), namespace: namespace)
        .frame(
            width: Theme.Metrics.expandedNotchSize.width,
            height: Theme.Metrics.expandedNotchSize.height
        )
        .background(.black)
}

#Preview("Plan review") {
    PlanReviewView(
        request: AgentsPreviewData.plan,
        onSend: { _ in },
        onApprove: {}
    )
    .frame(
        width: Theme.Metrics.expandedNotchSize.width,
        height: Theme.Metrics.expandedNotchSize.height
    )
    .background(.black)
}
