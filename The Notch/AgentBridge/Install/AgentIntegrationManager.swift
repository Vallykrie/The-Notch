import Combine
import Foundation

nonisolated struct AgentIntegrationStatus: Identifiable, Sendable {
    var id: String { provider.rawValue }
    let provider: AgentCLI
    let installed: Bool
    let configured: Bool
    let error: String?
}

@MainActor
final class AgentIntegrationManager: ObservableObject {
    @Published private(set) var statuses: [AgentIntegrationStatus] = []
    private var isRefreshing = false
    private var task: Task<Void, Never>?
    /// Where the user's answer to "may I hook into your agents?" lives. `nil` only in previews,
    /// which never install anything.
    private weak var settings: NotchSettings?

    init(settings: NotchSettings? = nil) {
        self.settings = settings
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() { task?.cancel(); task = nil }

    /// The agents the user may be asked about: detected on this Mac, whether or not they are
    /// hooked up yet.
    var detected: [AgentIntegrationStatus] {
        statuses.filter(\.installed)
    }

    /// Re-detects every agent and, if the user has agreed, keeps each one's hook in place.
    ///
    /// Detection always runs; installation only with consent, and never for an agent the user
    /// unticked. A hook that is already there is reported as configured either way — it may
    /// have been put there by an earlier version that did not ask, and it is the user's to
    /// remove, not ours.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let source = Bundle.main.url(forResource: "notch-hook", withExtension: nil)
        let mayInstall = settings?.agentHookConsent == .granted
        let declined = settings?.declinedAgentHooks ?? []
        let result = await Task.detached(priority: .utility) {
            let detected = AgentCLIDetector().detect()
            return detected.map { status -> AgentIntegrationStatus in
                guard status.isInstalled else {
                    return AgentIntegrationStatus(provider: status.agent, installed: false, configured: false, error: nil)
                }
                guard mayInstall, !declined.contains(status.agent.rawValue) else {
                    return AgentIntegrationStatus(provider: status.agent, installed: true, configured: status.isHooked, error: nil)
                }
                guard let source else {
                    return AgentIntegrationStatus(provider: status.agent, installed: true, configured: false, error: "Bridge binary missing")
                }
                do {
                    try HookInstaller(binarySourceURL: source).install(for: status.agent)
                    return AgentIntegrationStatus(provider: status.agent, installed: true, configured: true, error: nil)
                } catch {
                    return AgentIntegrationStatus(provider: status.agent, installed: true, configured: false, error: error.localizedDescription)
                }
            }
        }.value
        guard !Task.isCancelled else { return }
        statuses = result
    }

    /// Records the user's yes, for every detected agent except the ones they unticked, and
    /// installs straight away so the rows can say "hooked" while they are still looking.
    func connect(excluding declined: Set<AgentCLI>) async {
        settings?.declinedAgentHooks = Set(declined.map(\.rawValue))
        settings?.agentHookConsent = .granted
        await refresh()
    }

    /// The user's "not now". Nothing already in their config is removed.
    func decline() {
        settings?.agentHookConsent = .declined
    }

    #if DEBUG
    /// Previews and `FrameDump` only. Detection reads — and installs into — the real home
    /// directory, which a preview must never do.
    func seedPreviewStatuses(_ values: [AgentIntegrationStatus]) {
        statuses = values
    }
    #endif

    isolated deinit { task?.cancel() }
}
