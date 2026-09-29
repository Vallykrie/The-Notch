import Darwin
import Foundation

actor NotchHookServer {
    enum ServerError: LocalizedError {
        case alreadyRunning(String)
        case invalidSocketPath(String)
        case systemCall(String, Int32)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning(let path):
                "Another The Notch hook server is already listening at \(path)."
            case .invalidSocketPath(let path):
                "Unix socket path is too long: \(path)"
            case .systemCall(let operation, let code):
                "\(operation) failed (errno \(code)): \(String(cString: strerror(code)))"
            }
        }
    }

    private struct SocketIdentity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    private struct ClientConnection: Sendable {
        let descriptor: Int32
        var task: Task<Void, Never>?
    }

    static let defaultSocketPath = "/tmp/the-notch.sock"
    static let maximumLineBytes = 1_048_576

    private let store: AgentSessionStore
    private let socketPath: String
    private var listenerDescriptor: Int32?
    private var listenerTask: Task<Void, Never>?
    private var socketIdentity: SocketIdentity?
    private var connections: [UUID: ClientConnection] = [:]
    private(set) var isRunning = false

    init(store: AgentSessionStore, socketPath: String? = nil) {
        self.store = store
        self.socketPath = socketPath
            ?? ProcessInfo.processInfo.environment["THE_NOTCH_SOCKET"]
            ?? Self.defaultSocketPath
    }

    func start() async throws {
        guard !isRunning else { return }
        _ = try Self.socketAddress(for: socketPath)

        if Self.pathExists(socketPath) {
            if try Self.canConnect(to: socketPath) {
                throw ServerError.alreadyRunning(socketPath)
            }
            guard Darwin.unlink(socketPath) == 0 || errno == ENOENT else {
                throw ServerError.systemCall("unlink stale socket", errno)
            }
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ServerError.systemCall("socket", errno)
        }

        var didBind = false
        do {
            var (address, addressLength) = try Self.socketAddress(for: socketPath)
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, addressLength)
                }
            }
            guard bindResult == 0 else {
                throw ServerError.systemCall("bind", errno)
            }
            didBind = true

            guard Darwin.chmod(socketPath, mode_t(S_IRUSR | S_IWUSR)) == 0 else {
                throw ServerError.systemCall("chmod 0600", errno)
            }
            guard Darwin.listen(descriptor, SOMAXCONN) == 0 else {
                throw ServerError.systemCall("listen", errno)
            }
            guard let identity = Self.identity(of: socketPath) else {
                throw ServerError.systemCall("lstat bound socket", errno)
            }

            listenerDescriptor = descriptor
            socketIdentity = identity
            isRunning = true
            listenerTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else {
                    Darwin.close(descriptor)
                    return
                }
                await Self.runAcceptLoop(descriptor: descriptor, server: self)
            }
        } catch {
            Darwin.close(descriptor)
            if didBind {
                Darwin.unlink(socketPath)
            }
            throw error
        }
    }

    func stop() async {
        guard isRunning || listenerDescriptor != nil else { return }
        isRunning = false

        if let descriptor = listenerDescriptor {
            Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            listenerDescriptor = nil
        }
        listenerTask?.cancel()
        let acceptTask = listenerTask
        listenerTask = nil

        let clientTasks = connections.values.compactMap(\.task)
        for connection in connections.values {
            Darwin.shutdown(connection.descriptor, SHUT_RDWR)
            connection.task?.cancel()
        }
        await acceptTask?.value
        for task in clientTasks {
            await task.value
        }

        for connection in connections.values {
            Darwin.close(connection.descriptor)
        }
        connections.removeAll()
        unlinkSocketIfStillOwned()
        socketIdentity = nil
    }

    private nonisolated static func runAcceptLoop(
        descriptor: Int32,
        server: NotchHookServer
    ) async {
        while !Task.isCancelled {
            let clientDescriptor = Darwin.accept(descriptor, nil, nil)
            if clientDescriptor >= 0 {
                await server.accept(clientDescriptor)
                continue
            }
            if errno == EINTR { continue }
            if errno == EBADF || errno == EINVAL || Task.isCancelled { return }
            await Task.yield()
        }
    }

    private func accept(_ descriptor: Int32) {
        guard isRunning else {
            Darwin.close(descriptor)
            return
        }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            Darwin.setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        let connectionID = UUID()
        connections[connectionID] = ClientConnection(descriptor: descriptor, task: nil)
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                Darwin.close(descriptor)
                return
            }
            await Self.runConnection(
                descriptor: descriptor,
                connectionID: connectionID,
                server: self
            )
        }
        connections[connectionID]?.task = task
    }

    private nonisolated static func runConnection(
        descriptor: Int32,
        connectionID: UUID,
        server: NotchHookServer
    ) async {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 8_192)
        var shouldContinue = true

        while shouldContinue, !Task.isCancelled {
            let count = chunk.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }

            buffer.append(contentsOf: chunk.prefix(count))
            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                if newlineIndex > maximumLineBytes {
                    shouldContinue = false
                    break
                }
                var line = Data(buffer[..<newlineIndex])
                buffer.removeSubrange(...newlineIndex)
                if line.last == 0x0D { line.removeLast() }
                if line.isEmpty { continue }

                if let response = await server.handleLine(line),
                   !writeAll(response, to: descriptor) {
                    shouldContinue = false
                    break
                }
            }
            if buffer.count > maximumLineBytes {
                shouldContinue = false
            }
        }

        await server.connectionEnded(connectionID)
    }

    private func handleLine(_ line: Data) async -> Data? {
        guard let request = try? JSONDecoder().decode(HookRequest.self, from: line) else {
            return nil
        }

        guard request.eventName == .permissionRequest else {
            await store.handle(request)
            return nil
        }

        // The notch only *announces* a permission prompt; it never answers one. The agent is
        // told to defer at once, so its own terminal prompt appears immediately and is where
        // the user decides. The panel shows the request until the session moves on.
        await store.registerPermissionNotice(request)
        let response = HookResponse(id: request.id, decision: .defer)
        guard var data = try? JSONEncoder().encode(response) else { return nil }
        data.append(0x0A)
        return data
    }

    private func connectionEnded(_ connectionID: UUID) {
        guard let connection = connections.removeValue(forKey: connectionID) else { return }
        Darwin.shutdown(connection.descriptor, SHUT_RDWR)
        Darwin.close(connection.descriptor)
    }

    private func unlinkSocketIfStillOwned() {
        guard let socketIdentity,
              Self.identity(of: socketPath) == socketIdentity else {
            return
        }
        Darwin.unlink(socketPath)
    }

    private nonisolated static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return true }
            var written = 0
            while written < bytes.count {
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written,
                    0
                )
                if count > 0 {
                    written += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
    }

    private nonisolated static func pathExists(_ path: String) -> Bool {
        var status = stat()
        return Darwin.lstat(path, &status) == 0
    }

    private nonisolated static func identity(of path: String) -> SocketIdentity? {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0 else { return nil }
        return SocketIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
    }

    private nonisolated static func canConnect(to path: String) throws -> Bool {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw ServerError.systemCall("probe socket", errno)
        }
        defer { Darwin.close(descriptor) }

        var (address, addressLength) = try socketAddress(for: path)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        return result == 0
    }

    private nonisolated static func socketAddress(
        for path: String
    ) throws -> (sockaddr_un, socklen_t) {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard !pathBytes.contains(0), pathBytes.count + 1 <= capacity else {
            throw ServerError.invalidSocketPath(path)
        }

        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path) ?? 2
        let length = socklen_t(pathOffset + pathBytes.count + 1)
        return (address, length)
    }
}
