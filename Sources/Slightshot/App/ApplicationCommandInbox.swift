import Foundation
import Darwin

/// Every bundle copy shares this private, per-user inbox. The process holding
/// owner.lock is the only one allowed to create menu items or register hotkeys.
/// Never unlink lock files: replacing their inode would allow a second owner.
final class ApplicationCommandInbox {
    enum RoutingError: Error {
        case ownerUnavailable
        case inboxFull
    }

    private struct Request: Codable {
        let command: ApplicationCommand
        let date: Date
    }

    private struct State: Codable {
        let owner: UUID
        var requests: [Request]
    }

    let isOwner: Bool
    let directory: URL
    private let ownerDescriptor: Int32
    private let ownerID: UUID
    private let now: () -> Date
    private var watchSource: DispatchSourceFileSystemObject?

    static func userDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
            .appendingPathComponent("com.jmpijll.slightshot/Commands", isDirectory: true)
    }

    init(directory: URL, now: @escaping () -> Date = Date.init) throws {
        self.directory = directory
        self.now = now
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let descriptor = try Self.openLock(directory.appendingPathComponent("owner.lock"))
        do {
            // Serialize election and generation publication with forwarding.
            // A racing loser cannot observe the preceding owner's inbox.
            let ownership = try Self.withInboxLock(directory) {
                if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                    let state = State(owner: UUID(), requests: [])
                    try Self.write(state, directory: directory)
                    return (true, state.owner)
                }
                guard errno == EWOULDBLOCK else { throw Self.posixError() }
                return (false, try Self.read(directory).owner)
            }
            ownerDescriptor = descriptor
            isOwner = ownership.0
            ownerID = ownership.1
        } catch {
            close(descriptor)
            throw error
        }
    }

    isolated deinit {
        watchSource?.cancel()
        close(ownerDescriptor)
    }

    func startReceiving(_ receive: @escaping @MainActor (ApplicationCommand) -> Void) throws {
        guard isOwner else { throw RoutingError.ownerUnavailable }
        guard watchSource == nil else { return }
        let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.posixError() }
        // Watch the directory because atomic writes replace the inbox's inode.
        // Resume before draining, so a write racing startup cannot be missed.
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                do {
                    for command in try self?.takePending() ?? [] { receive(command) }
                } catch {
                    Log.app.error("Command inbox could not be read: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        watchSource = source
        source.resume()
        for command in try takePending() { receive(command) }
    }

    func stopReceiving() {
        watchSource?.cancel()
        watchSource = nil
    }

    func send(_ command: ApplicationCommand) throws {
        try Self.withInboxLock(directory) {
            if !isOwner {
                // If the owner has exited, do not leave a capture for a future launch.
                if flock(ownerDescriptor, LOCK_EX | LOCK_NB) == 0 {
                    flock(ownerDescriptor, LOCK_UN)
                    throw RoutingError.ownerUnavailable
                }
                guard errno == EWOULDBLOCK else { throw Self.posixError() }
            }
            var state = try Self.read(directory)
            guard state.owner == ownerID else { throw RoutingError.ownerUnavailable }
            state.requests.removeAll { !isRecent($0, at: now()) }
            guard state.requests.count < 16 else { throw RoutingError.inboxFull }
            state.requests.append(Request(command: command, date: now()))
            try Self.write(state, directory: directory)
        }
    }

    func takePending() throws -> [ApplicationCommand] {
        guard isOwner else { return [] }
        return try Self.withInboxLock(directory) {
            var state = try Self.read(directory)
            guard state.owner == ownerID else { throw RoutingError.ownerUnavailable }
            guard !state.requests.isEmpty else { return [] }
            let commands = state.requests.filter { isRecent($0, at: now()) }.map(\.command)
            state.requests.removeAll()
            try Self.write(state, directory: directory)
            return commands
        }
    }

    private func isRecent(_ request: Request, at date: Date) -> Bool {
        let age = date.timeIntervalSince(request.date)
        return age >= 0 && age <= 10
    }

    private static func withInboxLock<T>(_ directory: URL, perform: () throws -> T) throws -> T {
        let descriptor = try openLock(directory.appendingPathComponent("inbox.lock"))
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw posixError() }
        return try perform()
    }

    private static func openLock(_ url: URL) throws -> Int32 {
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        return descriptor
    }

    private static func read(_ directory: URL) throws -> State {
        try JSONDecoder().decode(State.self, from: Data(contentsOf: directory.appendingPathComponent("inbox.json")))
    }

    private static func write(_ state: State, directory: URL) throws {
        let url = directory.appendingPathComponent("inbox.json")
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
