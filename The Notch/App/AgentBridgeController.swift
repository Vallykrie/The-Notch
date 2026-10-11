import Combine
import Foundation

/// Owns the agent bridge's lifetime and connects it to the notch.
///
/// The bridge is two halves that otherwise know nothing about each other: `NotchHookServer`
/// receives hook events over a Unix socket, and `AgentSessionStore` turns them into UI state.
/// This type starts them, keeps them alive for the life of the app, and applies the one
/// behaviour that spans both — surfacing the notch when an agent is blocked waiting on the user.
@MainActor
final class AgentBridgeController {
    /// Why the bridge is not currently accepting events. Surfaced so the UI can explain itself
    /// rather than silently showing an empty session list.
    enum Status {
        case stopped
        case running
        /// Another instance already owns the socket. We defer to it instead of fighting over
        /// the path, because two servers answering the same approval would be worse than none.
        case socketUnavailable(String)
        case failed(String)
    }

    let store: AgentSessionStore

    private(set) var status: Status = .stopped

    private let server: NotchHookServer
    private let coordinator: NotchCoordinator
    private let sounds: SoundEffects
    private var startTask: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private let codexSessions = CodexSessionReader()
    private var codexTask: Task<Void, Never>?
    private var pruneTask: Task<Void, Never>?

    /// Approval IDs we have already sounded for. `pendingApprovals` republishes on every
    /// mutation, including unrelated ones, so identity is the only reliable way to tell a new
    /// request from a redelivery of the same list.
    private var announcedApprovals: Set<UUID> = []

    /// Last known status per session, so we can sound on the *transition* rather than on every
    /// republication of a session that happens to be sitting in `.done`.
    private var lastKnownStatus: [String: SessionStatus] = [:]

    init(coordinator: NotchCoordinator, socketPath: String? = nil, sounds: SoundEffects? = nil) {
        let store = AgentSessionStore()
        self.store = store
        self.coordinator = coordinator
        self.sounds = sounds ?? .shared
        self.server = NotchHookServer(store: store, socketPath: socketPath)
    }

    func start() {
        guard startTask == nil else { return }

        sounds.preload()
        observeApprovals()
        observeSessionStatuses()
        schedulePruning()
        codexTask = Task { [weak self, codexSessions] in
            while !Task.isCancelled {
                let events = await codexSessions.poll()
                guard !Task.isCancelled else { return }
                for event in events { self?.store.handleObserved(event) }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        startTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await server.start()
                status = .running
            } catch let error as NotchHookServer.ServerError {
                switch error {
                case .alreadyRunning(let path):
                    status = .socketUnavailable(path)
                case .invalidSocketPath, .systemCall:
                    status = .failed(error.localizedDescription)
                }
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }

    func stop() async {
        startTask?.cancel()
        startTask = nil
        observers.removeAll()
        sounds.stopAll()
        codexTask?.cancel()
        codexTask = nil
        pruneTask?.cancel()
        pruneTask = nil
        await server.stop()
        status = .stopped
    }

    /// An agent blocked on a permission request is the one event that earns the right to take
    /// over the notch unprompted — the agent is stalled until the user answers.
    private func observeApprovals() {
        store.$pendingApprovals
            .map { $0.min(by: { $0.requestedAt < $1.requestedAt }).map { $0.question == nil } }
            .removeDuplicates()
            .sink { [weak self] oldestIsPermission in
                guard let self else { return }
                // The controller only says *what* happened; `NotchRootView` decides how the
                // notch moves for it — a pop for a permission, a drip for a question — and
                // whether it closes again once the prompt is gone. Releasing does not send the
                // user anywhere: if they opened the panel themselves, it stays theirs.
                switch oldestIsPermission {
                case true?: coordinator.raiseAttention(.approval)
                case false?: coordinator.raiseAttention(.question)
                case nil: coordinator.raiseAttention(.resolved)
                }
            }
            .store(in: &observers)

        store.$pendingApprovals
            .sink { [weak self] approvals in
                self?.announce(approvals)
            }
            .store(in: &observers)

        // `coordinator.hasAgentActivity` is deliberately *not* set from here, even though
        // this is where the session data arrives.
        //
        // Setting it changes `collapsedSize`, and the resting silhouette has to animate to
        // that new width. The only place that can happen is inside the `withAnimation` that
        // also moves `NotchRootView`'s mirrored `animatedCollapsedSize` — the view mirrors
        // the size because a published change alone arrives after the transaction that caused
        // it has already closed (the long comment on that view's `.onReceive` explains why).
        // A second writer here would race that one: if this sink landed first, the view's
        // mirror would animate toward the size the flag had a moment ago and the shoulders
        // would simply never appear.
        //
        // So the view owns both flags, media and agents alike, and this controller owns only
        // the takeover above.
    }

    /// Sounds once per *new* approval. The panel taking itself over is easy to miss when the
    /// user is looking at another display or another app, which is exactly the case this cue
    /// exists for. Resolved approvals are forgotten so a genuinely new request for the same
    /// tool later still sounds.
    private func announce(_ approvals: [PendingApproval]) {
        let current = Set(approvals.map(\.approvalID))
        let isNew = !current.subtracting(announcedApprovals).isEmpty
        announcedApprovals = current
        if isNew {
            sounds.play(.approvalRequested)
        }
    }

    /// Sounds on the two session transitions the user cares about while looking elsewhere:
    /// a run ending, and an agent stopping to ask something.
    ///
    /// Only transitions count. `sessionsByID` republishes on every hook event — including token
    /// updates for a session that has been sitting in `.done` for minutes — so comparing
    /// against the last known status is what keeps this from becoming a metronome. A session
    /// seen for the first time never sounds, which also keeps a restart from replaying the
    /// history it just loaded.
    private func observeSessionStatuses() {
        store.$sessionsByID
            .sink { [weak self] sessions in
                guard let self else { return }
                for (id, session) in sessions {
                    let previous = lastKnownStatus.updateValue(session.status, forKey: id)
                    guard let previous, previous != session.status else { continue }
                    switch session.status {
                    case .waitingForAnswer:
                        // A question or plan is on screen and the run is blocked on it.
                        sounds.play(.questionAsked)

                    case .waitingForInput, .done:
                        // Both mean "the agent stopped and it is your move" — one for a turn
                        // ending, one for the whole session ending. A session that ends its
                        // turn and then closes passes through both, but `sessionFinished`'s
                        // cooldown is longer than that gap, so it sounds once.
                        sounds.play(.sessionFinished)
                        // Only a run that was actually running is celebrated: a session going
                        // from waiting to done is a close, not a finish. Subagents report to
                        // their parent, which finishes on its own.
                        if previous.isBusy, !session.isSubagent {
                            coordinator.raiseAttention(.finished(sessionID: id))
                        }

                    case .needsApproval:
                        // Intentionally silent: the approval observer above already sounds for
                        // this, off a richer signal that knows which approval arrived.
                        break

                    case .working, .thinking, .runningTool, .compacting, .idle:
                        // Progress, not events. These change constantly during a normal run and
                        // none of them is the user's cue to do anything.
                        break
                    }
                }
                lastKnownStatus = lastKnownStatus.filter { sessions[$0.key] != nil }
            }
            .store(in: &observers)
    }

    /// Age waiting turns into idle, retire inactive rows, and prune finished sessions using
    /// the selected retention even when no new hook events arrive.
    private func schedulePruning() {
        pruneTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    return
                }
                self?.store.pruneDoneSessions()
            }
        }
    }
}
