import Combine
import Foundation

/// What a session is doing right now.
///
/// Eight of these describe an agent that is alive; `idle` is the ninth, and covers the gap
/// between "we have heard of this session" and "we have classified an event from it".
///
/// The split between `working`, `thinking`, and `runningTool` is deliberate even though all
/// three mean "busy". They answer the question the user actually asks when they glance at the
/// notch — *is it burning tokens or is it touching my machine?* — and `Theme` already carries a
/// distinct hue for each. Likewise `waitingForInput` (your turn, say anything) and
/// `waitingForAnswer` (a specific question is on screen) demand different responses from the
/// user, so they are different states rather than one state with a note attached.
///
/// Raw values are stable: the five original cases keep their spelling so any persisted or
/// in-flight value still decodes.
nonisolated enum SessionStatus: String, Codable, Sendable, CaseIterable {
    /// The agent is in a turn but not currently inside a tool call.
    case working
    /// Extended reasoning — tokens are burning, nothing is being touched.
    case thinking
    /// A tool call is in flight.
    case runningTool
    /// Blocked on an allow/deny decision. This is the state the whole app exists for.
    case needsApproval
    /// A specific question or plan is on screen, blocked on the user's answer.
    case waitingForAnswer
    /// The turn ended. The session is alive and it is the user's move.
    case waitingForInput
    /// Compacting the transcript. Long, common, and not the user's problem.
    case compacting
    /// The session itself ended.
    case done
    /// Known session with no classified activity, or a turn left waiting for five minutes.
    case idle

    /// Unknown raw values decode to `idle` rather than throwing. A future build of this app —
    /// or a future agent — inventing a state must not make an entire payload undecodable.
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .idle
    }
}

nonisolated struct SessionEventLogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let eventName: EventName
    let message: String?
    let toolName: String?
}

nonisolated struct AgentSession: Identifiable, Sendable {
    let id: String
    let kind: AgentKind
    let cwd: String
    let projectDisplayName: String
    var status: SessionStatus
    var lastActivity: Date
    /// When the user last actually said something to this session. Distinct from
    /// `lastActivity`, which any tool call from any thread moves — see the panel's ordering in
    /// `sessions`.
    var lastPromptAt: Date?
    var currentTool: String?
    var recentEvents: [SessionEventLogEntry]
    /// The session this one was spawned by, or `nil` for a session you started yourself.
    ///
    /// A subagent is not another agent. It has no prompt of its own, it ends when its parent
    /// stops needing it, and there can be five of them behind one thing the user asked for —
    /// so it is a child of a row rather than a row.
    var parentID: String?
    /// `Explore`, `general-purpose`, whatever the agent was asked for. The child row's title,
    /// because a subagent has no project of its own to be named after.
    var agentType: String?
    /// The transcript this session writes to, which is where its token usage is read from.
    var transcriptPath: String?
    var inputTokens: Int64?
    var outputTokens: Int64?
    var totalTokens: Int64?
    /// How much context the session is carrying right now — see `TranscriptUsage`.
    var contextTokens: Int64?
    var costUSD: Double?
    /// The model id as the agent reports it (`claude-opus-4-5-20251101`, `gpt-5.1-codex`) —
    /// see `ModelName` for what the row shows.
    var model: String?
    /// The terminal, IDE or desktop app the session runs in, when it could be worked out.
    var host: AgentHost?

    var isSubagent: Bool { parentID != nil }

    /// What the panel sorts on: when the user last spoke to this session, falling back to any
    /// activity for a session we have never seen a prompt from (one resumed from before the
    /// notch was running, or an agent whose CLI does not send `UserPromptSubmit`).
    var conversationOrderKey: Date { lastPromptAt ?? lastActivity }

    /// What the row calls this session. A subagent is named by what it is, because every
    /// subagent of a session shares that session's project and directory.
    var displayName: String {
        guard let agentType, !agentType.isEmpty else { return projectDisplayName }
        return agentType
    }
}

nonisolated struct PendingApproval: Identifiable, Sendable {
    var id: UUID { approvalID }

    let approvalID: UUID
    let sessionID: String
    let kind: AgentKind
    let cwd: String
    let projectDisplayName: String
    let toolName: String?
    let toolInputSummary: String?
    let message: String?
    let requestedAt: Date
    /// Set when this is not a permission decision at all but a question with answers — see
    /// `ApprovalQuestion`.
    let question: ApprovalQuestion?
}

@MainActor
final class AgentSessionStore: ObservableObject {
    nonisolated static let recentEventLimit = 50
    nonisolated static let defaultDoneSessionRetention: TimeInterval = 15 * 60
    nonisolated static let waitingForInputIdleDelay: TimeInterval = 5 * 60
    /// UI retention only: retiring an inactive row never ends the underlying agent session.
    nonisolated static let inactiveSessionRetention: TimeInterval = 15 * 60
    /// How long a session may claim to be busy without a single event before we stop believing
    /// it. A turn can end with no `Stop` at all — Claude sends none when the user interrupts,
    /// and a killed process sends nothing — so without this a busy row had no way out. Twice
    /// the resting retention and three times Claude's longest Bash timeout, so a genuinely long
    /// tool call is not mistaken for a dead one; if it is, its next event brings the row back.
    nonisolated static let silentBusySessionRetention: TimeInterval = 30 * 60
    /// How long a finished subagent stays under its parent. Long enough to see what ran and
    /// what it cost, short enough that a swarm does not leave a wall of them.
    nonisolated static let finishedSubagentRetention: TimeInterval = 90

    @Published private(set) var sessionsByID: [String: AgentSession] = [:]
    @Published private(set) var pendingApprovals: [PendingApproval] = []

    private let usageReader = TranscriptUsageReader()
    /// One transcript read per session at a time. Events arrive faster than a read completes
    /// during a tool loop, and queueing them would only re-read the same tail.
    private var usageReadsInFlight: Set<String> = []

    /// How long a finished session stays before `handle` prunes it. An instance value rather
    /// than the static default because the user can change it in settings; the static remains
    /// the shipped default and the seed for `FinishedRetention.standard`.
    var doneSessionRetention: TimeInterval = AgentSessionStore.defaultDoneSessionRetention

    /// The sessions the user started, newest conversation first. Subagents are not here; they
    /// belong to a row rather than being one — see `children(of:)`.
    ///
    /// Ordered by when the user last *typed into* the session, not by when it last did
    /// something. Those are different questions and the second one answers the wrong one: an
    /// agent grinding through a long tool loop emits an event every few seconds, so it pinned
    /// itself to the top of the panel and pushed the session you just gave work to underneath
    /// it. The session you last spoke to is the one you are thinking about, so it leads — and
    /// with it the sprite on the collapsed shoulder, which shows the leading session.
    ///
    /// Finished sessions still sink to the bottom regardless: they are not part of the ordering
    /// question, they are the residue of it.
    var sessions: [AgentSession] {
        sessionsByID.values
            .filter { !$0.isSubagent }
            .sorted(by: Self.isOrderedBefore)
    }

    /// The subagents a session has spawned, oldest first so a running list does not reshuffle
    /// itself under the pointer as each one reports in.
    func children(of sessionID: String) -> [AgentSession] {
        sessionsByID.values
            .filter { $0.parentID == sessionID }
            .sorted { $0.lastActivity < $1.lastActivity }
    }

    func session(for id: String) -> AgentSession? {
        sessionsByID[id]
    }

    private static func isOrderedBefore(_ left: AgentSession, _ right: AgentSession) -> Bool {
        if left.status == .done, right.status != .done { return false }
        if left.status != .done, right.status == .done { return true }
        return left.conversationOrderKey > right.conversationOrderKey
    }

    func handleObserved(_ event: ObservedAgentEvent) {
        let id = Self.sessionID(for: event.request)
        // Hooks arrive live; an older transcript record must never rewind that state.
        if let current = sessionsByID[id], current.lastActivity >= event.date {
            // The record is stale as *state*, but the model it names is still news: Codex's
            // hooks never say which model is running, only its session file does.
            if let model = event.request.model, !model.isEmpty, current.model != model {
                sessionsByID[id]?.model = model
            }
            if current.host == nil, let originator = event.request.codexOriginator {
                sessionsByID[id]?.host = AgentHostResolver.codexHost(originator: originator)
            }
            return
        }
        handle(event.request, at: event.date)
    }

    func handle(_ request: HookRequest, at date: Date = Date()) {
        pruneDoneSessions(olderThan: doneSessionRetention, now: date)

        let sessionID = Self.sessionID(for: request)
        var session = sessionsByID[sessionID] ?? Self.makeSession(
            id: sessionID,
            request: request,
            date: date
        )

        session.lastActivity = date
        if request.eventName == .userPromptSubmit || request.eventName == .sessionStart {
            session.lastPromptAt = date
        }
        if let path = Self.transcriptPath(for: request, isSubagent: session.isSubagent) {
            session.transcriptPath = path
        }
        if session.isSubagent, let agentType = request.agentType, !agentType.isEmpty {
            session.agentType = agentType
        }
        if let model = request.model, !model.isEmpty {
            session.model = model
        }
        if let host = request.host {
            session.host = host
        } else if session.host == nil, let originator = request.codexOriginator {
            session.host = AgentHostResolver.codexHost(originator: originator)
        }
        if let transition = Self.transition(for: request, isSubagent: session.isSubagent) {
            session.status = transition.status
            switch transition.tool {
            case .clear: session.currentTool = nil
            case .set: session.currentTool = request.toolName ?? session.currentTool
            case .keep: break
            }
        }

        pendingApprovals.removeAll {
            $0.sessionID == sessionID && Self.clearsPermissionNotice($0, after: request)
        }

        // A blocked approval outranks whatever telemetry arrives while the agent waits. Codex
        // and Claude both keep emitting events from other threads during a permission prompt,
        // and letting one of those quietly repaint the session as "working" would hide the very
        // thing the user has to act on.
        if session.status != .done,
           let blocking = pendingApprovals.first(where: { $0.sessionID == sessionID }) {
            session.status = blocking.question == nil ? .needsApproval : .waitingForAnswer
        }

        session.recentEvents.append(
            SessionEventLogEntry(
                id: UUID(),
                timestamp: date,
                eventName: request.eventName,
                message: request.messageText ?? request.toolInputSummary,
                toolName: request.toolName
            )
        )
        if session.recentEvents.count > Self.recentEventLimit {
            session.recentEvents.removeFirst(session.recentEvents.count - Self.recentEventLimit)
        }

        updateUsage(on: &session, from: request.payload)
        sessionsByID[sessionID] = session

        // A subagent's first event is the only announcement its parent gets that it exists, and
        // the parent must not be left looking idle while its helpers work.
        if let parentID = session.parentID, var parent = sessionsByID[parentID] {
            parent.lastActivity = date
            sessionsByID[parentID] = parent
        }

        refreshUsageFromTranscript(sessionID: sessionID)
    }

    /// Folds token usage read from the session's own transcript into the row.
    ///
    /// Hook payloads carry no usage at all — every number the panel shows comes from here. The
    /// read is incremental and off this actor (see `TranscriptUsageReader`), so an event storm
    /// during a tool loop costs a seek and the bytes appended since the last one.
    private func refreshUsageFromTranscript(sessionID: String) {
        guard let path = sessionsByID[sessionID]?.transcriptPath, !path.isEmpty else { return }
        guard !usageReadsInFlight.contains(sessionID) else { return }
        usageReadsInFlight.insert(sessionID)

        Task { [usageReader] in
            let usage = await usageReader.usage(forPath: path)
            await MainActor.run {
                self.usageReadsInFlight.remove(sessionID)
                guard let usage, var session = self.sessionsByID[sessionID] else { return }
                if let context = usage.contextTokens { session.contextTokens = context }
                if let output = usage.outputTokens { session.outputTokens = output }
                if let input = usage.inputTokens { session.inputTokens = input }
                if let cost = usage.costUSD { session.costUSD = cost }
                if let model = usage.model { session.model = model }
                if session.totalTokens == nil,
                   usage.inputTokens != nil || usage.outputTokens != nil {
                    session.totalTokens = (usage.inputTokens ?? 0) + (usage.outputTokens ?? 0)
                }
                self.sessionsByID[sessionID] = session
            }
        }
    }

    /// Shows a permission prompt or question in the panel. Announcement only: the server has
    /// already told the agent to defer, so the answer is given in the agent's own terminal and
    /// the notice clears itself when the session moves on — see `clearsPermissionNotice`.
    func registerPermissionNotice(_ request: HookRequest, at date: Date = Date()) {
        handle(request, at: date)
        let sessionID = Self.sessionID(for: request)
        let projectName = sessionsByID[sessionID]?.projectDisplayName
            ?? Self.projectDisplayName(for: request.cwd)

        pendingApprovals.removeAll { $0.approvalID == request.id }
        pendingApprovals.append(
            PendingApproval(
                approvalID: request.id,
                sessionID: sessionID,
                kind: AgentKind(source: request.source),
                cwd: request.cwd,
                projectDisplayName: projectName,
                toolName: request.toolName,
                toolInputSummary: request.toolInputSummary,
                message: request.messageText,
                requestedAt: date,
                question: request.approvalQuestion
            )
        )
    }

    /// Dismisses a notice by hand, for a prompt answered in a way that emitted no event.
    func dismissApproval(approvalID: UUID) {
        let sessionID = removePendingApprovalFromUI(approvalID: approvalID)
        restoreSessionAfterApprovalIfNeeded(sessionID)
    }

    /// Whether an event means the user has answered the terminal prompt a notice stands for.
    /// A tool finishing counts only when it is the tool the notice was about, so a parallel
    /// call completing does not take down the notice for the one still waiting.
    private static func clearsPermissionNotice(
        _ approval: PendingApproval,
        after request: HookRequest
    ) -> Bool {
        switch request.eventName {
        case .postToolUse, .postToolUseFailure:
            guard let finished = request.toolName, let waiting = approval.toolName else {
                return true
            }
            return finished == waiting
        case .userPromptSubmit, .stop, .sessionStart, .sessionEnd, .permissionDenied, .preCompact:
            return true
        default:
            return false
        }
    }

    /// Whether the panel may offer a hide control for this session.
    ///
    /// A session with a pending approval must not be removable: its notice would be left
    /// pointing at a row that is no longer in the panel. Dismiss the notice first.
    func canHide(sessionID: String) -> Bool {
        guard sessionsByID[sessionID] != nil,
              !pendingApprovals.contains(where: { $0.sessionID == sessionID }) else {
            return false
        }
        // A subagent's approval is held by the subagent's row, and hiding the parent takes that
        // row with it — so the parent inherits its children's un-hideability.
        return !pendingApprovals.contains { approval in
            sessionsByID[approval.sessionID]?.parentID == sessionID
        }
    }

    /// Removes a session from the panel. Not a kill switch, and deliberately not a tombstone.
    ///
    /// The agent is untouched — this only forgets what we know about it. If the same session
    /// emits another event it is rebuilt from that event and reappears, which is the behaviour
    /// that matters: hiding is for the `waitingForInput` and `done` rows that pile up over a
    /// working day, and a hidden session that has genuinely gone back to work must not stay
    /// invisible. A suppression list would give the opposite behaviour and it would be
    /// undiscoverable, because the row it suppressed is the only place the user could turn it
    /// back on.
    @discardableResult
    func hideSession(id: String) -> Bool {
        guard canHide(sessionID: id) else { return false }
        // Subagents go with their parent. They are drawn as part of that row and have no
        // meaning without it, so leaving them behind would strand rows with nothing above them.
        for child in children(of: id) {
            sessionsByID.removeValue(forKey: child.id)
        }
        sessionsByID.removeValue(forKey: id)
        return true
    }

    /// Every session that is neither busy nor blocking. The panel's "clear" affordance.
    @discardableResult
    func hideRestingSessions() -> Int {
        let removable = sessionsByID.filter { id, session in
            !session.isSubagent
                && !session.status.isBusy
                && !session.status.demandsAttention
                && canHide(sessionID: id)
        }
        for id in removable.keys {
            _ = hideSession(id: id)
        }
        return removable.count
    }

    /// Periodic maintenance also retires inactive turns, independently of "Keep done".
    func pruneDoneSessions(
        olderThan retention: TimeInterval? = nil,
        now: Date = Date()
    ) {
        retireInactiveSessions(now: now)
        let cutoff = now.addingTimeInterval(-max(0, retention ?? doneSessionRetention))
        let subagentCutoff = now.addingTimeInterval(-Self.finishedSubagentRetention)
        var protectedSessionIDs = Set(pendingApprovals.map(\.sessionID))
        // A parent whose subagent is blocked has to survive, or the blocked row loses the row
        // it is drawn under.
        for id in protectedSessionIDs {
            if let parentID = sessionsByID[id]?.parentID {
                protectedSessionIDs.insert(parentID)
            }
        }

        sessionsByID = sessionsByID.filter { id, session in
            guard session.status == .done, !protectedSessionIDs.contains(id) else { return true }
            // Finished subagents clear out faster than sessions do. Half a dozen of them can
            // come and go inside one turn, and a row of tombstones under a working parent is
            // noise about work the user never asked to see itemised.
            return session.lastActivity >= (session.isSubagent ? subagentCutoff : cutoff)
        }
        // Orphans: a child outlives nothing. Its parent leaving is the end of it.
        sessionsByID = sessionsByID.filter { _, session in
            guard let parentID = session.parentID else { return true }
            return sessionsByID[parentID] != nil
        }
    }

    private func retireInactiveSessions(now: Date) {
        // Snapshot first: removing a parent also removes its children.
        for (id, session) in sessionsByID {
            let inactivity = now.timeIntervalSince(session.lastActivity)
            let isSilentBusy = session.status.isBusy
                && inactivity >= Self.silentBusySessionRetention
            guard session.status == .waitingForInput || session.status == .idle || isSilentBusy,
                  canHide(sessionID: id),
                  !children(of: id).contains(where: { child in
                      child.status.demandsAttention
                          || (child.status.isBusy
                              && now.timeIntervalSince(child.lastActivity)
                                  < Self.silentBusySessionRetention)
                  }) else { continue }

            if inactivity >= Self.inactiveSessionRetention {
                _ = hideSession(id: id)
            } else if session.status == .waitingForInput,
                      inactivity >= Self.waitingForInputIdleDelay {
                // This is a UI transition, not agent activity. Keep the timestamp so stale
                // transcript records cannot reset the timeout or supersede a newer hook.
                sessionsByID[id]?.status = .idle
            }
        }
    }

    private func removePendingApprovalFromUI(approvalID: UUID) -> String? {
        let sessionID = pendingApprovals.first { $0.approvalID == approvalID }?.sessionID
        pendingApprovals.removeAll { $0.approvalID == approvalID }
        return sessionID
    }

    private func restoreSessionAfterApprovalIfNeeded(_ sessionID: String?) {
        guard let sessionID,
              !pendingApprovals.contains(where: { $0.sessionID == sessionID }),
              var session = sessionsByID[sessionID],
              session.status == .needsApproval || session.status == .waitingForAnswer else {
            return
        }
        session.status = .working
        session.lastActivity = Date()
        sessionsByID[sessionID] = session
    }

    private func updateUsage(on session: inout AgentSession, from payload: [String: JSONValue]) {
        let root = JSONValue.object(payload)
        let input = Self.integerValue(
            root.firstValue(forKeys: ["input_tokens", "inputtokens", "prompt_tokens"])
        )
        let output = Self.integerValue(
            root.firstValue(forKeys: ["output_tokens", "outputtokens", "completion_tokens"])
        )
        let total = Self.integerValue(
            root.firstValue(forKeys: ["total_tokens", "totaltokens"])
        )
        let cost = root.firstValue(
            forKeys: ["cost_usd", "costusd", "total_cost", "totalcost", "usd", "cost"]
        )?.numberValue

        if let input { session.inputTokens = input }
        if let output { session.outputTokens = output }
        if let total {
            session.totalTokens = total
        } else if input != nil || output != nil {
            session.totalTokens = (session.inputTokens ?? 0) + (session.outputTokens ?? 0)
        }
        if let cost, cost.isFinite, cost >= 0 { session.costUSD = cost }
    }

    private static func integerValue(_ value: JSONValue?) -> Int64? {
        guard let number = value?.numberValue,
              number.isFinite,
              number >= 0,
              number <= Double(Int64.max) else {
            return nil
        }
        return Int64(number)
    }

    private enum ToolEffect {
        case set
        case clear
        case keep
    }

    /// The event → state machine.
    ///
    /// Returning `nil` means "this event changes nothing" — it is still logged, and the session
    /// keeps the state it had. Every unrecognised event lands there, which is what makes an
    /// unknown event harmless rather than a state corruption.
    private static func transition(
        for request: HookRequest,
        isSubagent: Bool
    ) -> (status: SessionStatus, tool: ToolEffect)? {
        switch request.eventName {
        case .sessionStart:
            // Opening a session is not starting work. This fires on launch, on `--resume`, on
            // `/clear`, and whenever the desktop app quietly relaunches a session in the
            // background — and in every one of those the agent is sitting at an empty prompt.
            // No `Stop` follows, because no turn ran, so reading it as `working` left the row
            // busy until something else came along. A compaction fires it mid-turn as well;
            // `preCompact` and `postCompact` already describe that, so it changes nothing.
            return request.sessionStartSource == "compact" ? nil : (.idle, .clear)

        case .userPromptSubmit:
            return (.working, .clear)

        case .preToolUse:
            // Presenting a plan or asking a question arrives as an ordinary tool call, but it
            // means the agent has stopped and is waiting on the human.
            return request.toolCategory.blocksOnUser
                ? (.waitingForAnswer, .set)
                : (.runningTool, .set)

        case .postToolUse, .postToolUseFailure:
            return (.working, .clear)

        case .agentThought:
            return (.thinking, .clear)

        case .elicitation, .exitPlanMode:
            return (.waitingForAnswer, .keep)

        case .permissionRequest:
            // A question arrives through the permission hook like everything else, and it is
            // not a permission decision — see `ApprovalQuestion`. The state has to agree with
            // the card the panel is about to draw, or the shoulder is amber for "allow this?"
            // while the panel asks which of four answers you want.
            return request.toolCategory.blocksOnUser
                ? (.waitingForAnswer, .set)
                : (.needsApproval, .set)

        case .permissionDenied:
            // The decision was made somewhere other than the notch; the agent carries on.
            return (.working, .clear)

        case .notification:
            return (.waitingForInput, .keep)

        case .preCompact:
            return (.compacting, .clear)

        case .postCompact:
            return (.working, .clear)

        case .stop:
            // `Stop` ends the *turn*, not the session — the agent is alive and it is the
            // user's move. Inactivity later makes this idle and retires the UI row;
            // only `SessionEnd` marks the underlying session as done.
            return (.waitingForInput, .clear)

        case .sessionEnd:
            return (.done, .clear)

        case .subagentStart:
            // Only the subagent's own row starts. The parent is still mid-turn and its state is
            // whatever it was doing when it delegated.
            return isSubagent ? (.working, .clear) : nil

        case .subagentStop:
            // Ends the *subagent*, and says nothing about the parent — which is exactly why
            // these used to be inert. Now that a subagent has a row of its own, that row is
            // what finishes.
            return isSubagent ? (.done, .clear) : nil

        case .unknown:
            return nil
        }
    }

    /// The row an event belongs to.
    ///
    /// A subagent's events carry the *parent's* `session_id` plus an `agent_id` of their own
    /// (verified against Claude Code 2.1.227 on the live socket), so keying on the session alone
    /// dropped every subagent tool call onto the parent's row: the row's status and current tool
    /// were whichever of five helpers happened to report last. Composing the two ids gives the
    /// subagent a row, and `parentSessionID` puts that row under the session that spawned it.
    private static func sessionID(for request: HookRequest) -> String {
        let parent = parentSessionID(for: request)
        guard let agentID = request.agentID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !agentID.isEmpty else {
            return parent
        }
        return "\(parent)\(subagentIDSeparator)\(agentID)"
    }

    private static func parentSessionID(for request: HookRequest) -> String {
        if let threadName = request.threadName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !threadName.isEmpty {
            return threadName
        }
        return "\(request.source.lowercased())|\(request.cwd)"
    }

    /// A character no session id or agent id contains, so the composite can never collide with
    /// a real id.
    private static let subagentIDSeparator = "\u{203A}"

    /// A subagent's transcript is its own file. Both paths can be present on the same event —
    /// `firstValue(forKeys:)` prefers the parent's — so the child asks for its own explicitly.
    private static func transcriptPath(for request: HookRequest, isSubagent: Bool) -> String? {
        if isSubagent, let path = request.agentTranscriptPath, !path.isEmpty {
            return path
        }
        guard let path = request.transcriptPath, !path.isEmpty else { return nil }
        return path
    }

    private static func makeSession(id: String, request: HookRequest, date: Date) -> AgentSession {
        let parentID = request.isSubagentEvent ? parentSessionID(for: request) : nil
        return AgentSession(
            id: id,
            kind: AgentKind(source: request.source),
            cwd: request.cwd,
            projectDisplayName: projectDisplayName(for: request.cwd),
            status: .idle,
            lastActivity: date,
            lastPromptAt: nil,
            currentTool: nil,
            recentEvents: [],
            parentID: parentID == id ? nil : parentID,
            agentType: request.agentType,
            transcriptPath: nil,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: nil,
            contextTokens: nil,
            costUSD: nil
        )
    }

    private static func projectDisplayName(for cwd: String) -> String {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown Project" }
        let name = URL(fileURLWithPath: trimmed).standardizedFileURL.lastPathComponent
        return name.isEmpty ? trimmed : name
    }
}
