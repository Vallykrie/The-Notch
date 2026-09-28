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

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let source = Bundle.main.url(forResource: "notch-hook", withExtension: nil)
        let result = await Task.detached(priority: .utility) {
            let detected = AgentCLIDetector().detect()
            return detected.map { status -> AgentIntegrationStatus in
                guard status.isInstalled else {
                    return AgentIntegrationStatus(provider: status.agent, installed: false, configured: false, error: nil)
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

    isolated deinit { task?.cancel() }
}
