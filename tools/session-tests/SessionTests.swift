import Foundation

@main
struct SessionTests {
    @MainActor
    static func main() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL"): \(name)")
            if !condition { failures += 1 }
        }
        func request(_ event: EventName, id: String = "session", payload: [String: JSONValue] = [:]) -> HookRequest {
            HookRequest(id: UUID(), eventName: event, source: "claude", cwd: "/tmp/project", threadName: id, timeout: nil, payload: payload)
        }
        let store = AgentSessionStore()
        store.handle(request(.stop), at: start)
        store.pruneDoneSessions(now: start.addingTimeInterval(299))
        check(store.session(for: "session")?.status == .waitingForInput, "waiting before five minutes")
        store.pruneDoneSessions(now: start.addingTimeInterval(300))
        check(store.session(for: "session")?.status == .idle, "idle at five minutes")
        check(store.session(for: "session")?.lastActivity == start, "timeout preserves real event timestamp")
        store.handleObserved(ObservedAgentEvent(request: request(.stop), date: start))
        check(store.session(for: "session")?.status == .idle, "duplicate transcript does not revive waiting state")
        store.pruneDoneSessions(now: start.addingTimeInterval(899))
        check(store.session(for: "session") != nil, "visible before fifteen minutes")
        store.pruneDoneSessions(now: start.addingTimeInterval(900))
        check(store.session(for: "session") == nil, "removed at fifteen minutes")
        store.handle(request(.userPromptSubmit), at: start.addingTimeInterval(901))
        check(store.session(for: "session")?.status == .working, "new prompt restores removed session")

        let resumed = AgentSessionStore()
        resumed.handle(request(.stop), at: start)
        resumed.pruneDoneSessions(now: start.addingTimeInterval(300))
        resumed.handle(request(.userPromptSubmit), at: start.addingTimeInterval(400))
        resumed.pruneDoneSessions(now: start.addingTimeInterval(2000))
        check(resumed.session(for: "session")?.status == .working, "resumed work survives old timeout")
        resumed.handle(request(.stop), at: start.addingTimeInterval(2001))
        resumed.pruneDoneSessions(now: start.addingTimeInterval(2300))
        check(resumed.session(for: "session")?.status == .waitingForInput, "new turn gets fresh waiting period")

        let sleeping = AgentSessionStore()
        sleeping.handle(request(.stop), at: start)
        sleeping.pruneDoneSessions(olderThan: 1e9, now: start.addingTimeInterval(3600))
        check(sleeping.sessions.isEmpty, "one sweep after sleep clears stale waiting even with Keep done")

        for event in [EventName.userPromptSubmit, .preToolUse, .postToolUse, .preCompact] {
            let active = AgentSessionStore()
            active.handle(request(event), at: start)
            let status = active.session(for: "session")?.status
            active.pruneDoneSessions(now: start.addingTimeInterval(1799))
            check(active.session(for: "session")?.status == status, "preserves \(event.rawValue) through a long silence")
            // An interrupted turn sends no Stop, so silence is the only end it ever gets.
            active.pruneDoneSessions(now: start.addingTimeInterval(1800))
            check(active.session(for: "session") == nil, "retires \(event.rawValue) left busy for thirty minutes")
        }

        let approval = AgentSessionStore()
        approval.handle(request(.permissionRequest), at: start)
        approval.pruneDoneSessions(now: start.addingTimeInterval(3600))
        check(approval.session(for: "session")?.status == .needsApproval, "preserves permissionRequest")

        for source in ["startup", "resume", "clear"] {
            let opened = AgentSessionStore()
            opened.handle(request(.sessionStart, payload: ["source": .string(source)]), at: start)
            check(opened.session(for: "session")?.status == .idle, "session start (\(source)) is not work")
            opened.pruneDoneSessions(now: start.addingTimeInterval(900))
            check(opened.session(for: "session") == nil, "untouched \(source) session retires at fifteen minutes")
        }

        let compacting = AgentSessionStore()
        compacting.handle(request(.preCompact), at: start)
        compacting.handle(request(.sessionStart, payload: ["source": .string("compact")]), at: start.addingTimeInterval(1))
        check(compacting.session(for: "session")?.status == .compacting, "compaction's session start leaves the turn alone")

        let parent = AgentSessionStore()
        parent.handle(request(.stop), at: start)
        parent.handle(request(.subagentStart, payload: ["agent_id": .string("child")]), at: start)
        parent.pruneDoneSessions(now: start.addingTimeInterval(1200))
        check(parent.session(for: "session")?.status == .waitingForInput, "busy child protects parent")
        parent.handle(request(.subagentStop, payload: ["agent_id": .string("child")]), at: start.addingTimeInterval(1201))
        parent.pruneDoneSessions(now: start.addingTimeInterval(2101))
        check(parent.sessionsByID.isEmpty, "inactive parent and finished children clear together")

        let abandoned = AgentSessionStore()
        abandoned.handle(request(.stop), at: start)
        abandoned.handle(request(.subagentStart, payload: ["agent_id": .string("child")]), at: start)
        abandoned.pruneDoneSessions(now: start.addingTimeInterval(1800))
        check(abandoned.sessionsByID.isEmpty, "child left busy does not pin its parent forever")

        let blocked = AgentSessionStore()
        blocked.handle(request(.stop), at: start)
        blocked.registerPermissionNotice(request(.permissionRequest, payload: ["agent_id": .string("child"), "tool_name": .string("AskUserQuestion")]), at: start)
        blocked.pruneDoneSessions(now: start.addingTimeInterval(3600))
        check(blocked.session(for: "session") != nil && blocked.pendingApprovals.count == 1, "child approval and parent remain reachable")

        func hosted(_ request: HookRequest, agent: pid_t, launchers: [pid_t] = []) -> HookRequest {
            var request = request
            request.host = AgentHost(
                bundleIdentifier: "com.example.terminal", name: "Terminal", agentProcessID: agent,
                tty: nil, termProgram: nil, termSessionID: nil, iTermSessionID: nil,
                launcherProcessIDs: launchers
            )
            return request
        }
        func headless(_ event: EventName, id: String, agent: pid_t, launchers: [pid_t]) -> HookRequest {
            hosted(
                HookRequest(id: UUID(), eventName: event, source: "antigravity", cwd: "/tmp/project/img", threadName: id, timeout: nil, payload: [:]),
                agent: agent, launchers: launchers
            )
        }
        let launching = AgentSessionStore()
        launching.handle(hosted(request(.preToolUse), agent: 100, launchers: [1]), at: start)
        launching.handle(hosted(request(.preToolUse, id: "other"), agent: 300, launchers: [1]), at: start)
        for run in ["run-a", "run-b", "run-c"] {
            launching.handle(headless(.postToolUse, id: run, agent: 200, launchers: [150, 100, 1]), at: start.addingTimeInterval(1))
        }
        check(launching.sessions.map(\.id).sorted() == ["other", "session"], "agents launched from a session are not sessions of their own")
        check(launching.children(of: "session").count == 3, "launched agents sit under the session that ran them")
        check(launching.session(for: "run-a")?.displayName == "Antigravity", "a launched agent is titled by what it is")
        check(launching.children(of: "other").isEmpty, "an unrelated session adopts nothing")
        launching.handle(headless(.stop, id: "run-a", agent: 200, launchers: [150, 100, 1]), at: start.addingTimeInterval(2))
        launching.pruneDoneSessions(now: start.addingTimeInterval(3 + AgentSessionStore.finishedSubagentRetention))
        check(launching.session(for: "run-a") == nil, "a finished launched agent clears like a subagent")

        let unrelated = AgentSessionStore()
        unrelated.handle(headless(.postToolUse, id: "solo", agent: 200, launchers: [150, 1]), at: start)
        check(unrelated.sessions.map(\.id) == ["solo"], "an agent with no agent above it stays a session")

        let done = AgentSessionStore()
        done.handle(request(.sessionEnd), at: start)
        done.pruneDoneSessions(olderThan: 3600, now: start.addingTimeInterval(1800))
        check(done.session(for: "session")?.status == .done, "finished retention remains separate")
        done.pruneDoneSessions(olderThan: 3600, now: start.addingTimeInterval(3601))
        check(done.sessions.isEmpty, "finished session expires at selected retention")
        let configured = AgentSessionStore()
        configured.doneSessionRetention = 3600
        configured.handle(request(.sessionEnd), at: start)
        configured.pruneDoneSessions(now: start.addingTimeInterval(1800))
        check(configured.session(for: "session")?.status == .done, "timer uses configured finished retention")
        configured.pruneDoneSessions(now: start.addingTimeInterval(3601))
        check(configured.sessions.isEmpty, "timer removes finished session after configured retention")

        let question = AgentSessionStore()
        question.handle(request(.permissionRequest, payload: ["tool_name": .string("AskUserQuestion")]), at: start)
        question.pruneDoneSessions(now: start.addingTimeInterval(3600))
        check(question.session(for: "session")?.status == .waitingForAnswer, "unanswered question never expires from inactivity")
        if failures > 0 { exit(1) }
    }
}
