import Foundation
import Testing
@testable import Slightshot

@MainActor
struct ApplicationCommandInboxTests {
    @Test func onlyOneCopyOwnsTheAppUntilItExits() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: ApplicationCommandInbox? = try ApplicationCommandInbox(directory: directory)
        #expect(owner?.isOwner == true)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        #expect(!duplicate.isOwner)
        owner = nil
        let replacement = try ApplicationCommandInbox(directory: directory)
        #expect(replacement.isOwner)
    }

    // Losing the notification during startup must not lose a request or replay it twice.
    @Test func duplicateForwardsBeforeOwnerStartsListening() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ApplicationCommandInbox(directory: directory)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        try duplicate.send(.capture(.copyFullScreen))
        try duplicate.send(.reopen)
        #expect(try duplicate.takePending() == [])
        #expect(try owner.takePending() == [.capture(.copyFullScreen), .reopen])
        #expect(try owner.takePending() == [])
    }

    @Test func restartDiscardsOldRequestsAndRejectsOldForwarders() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: ApplicationCommandInbox? = try ApplicationCommandInbox(directory: directory)
        #expect(owner?.isOwner == true)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        try duplicate.send(.capture(.saveFullScreen))
        owner = nil
        let replacement = try ApplicationCommandInbox(directory: directory)
        #expect(try replacement.takePending() == [])
        #expect(throws: ApplicationCommandInbox.RoutingError.self) {
            try duplicate.send(.capture(.captureArea))
        }
        #expect(try replacement.takePending() == [])
    }

    @Test func expiredRequestsNeverStartDelayedCaptures() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000)
        let owner = try ApplicationCommandInbox(directory: directory, now: { now })
        let duplicate = try ApplicationCommandInbox(directory: directory, now: { now })
        try duplicate.send(.capture(.captureArea))
        #expect(try owner.takePending() == [.capture(.captureArea)])
        try duplicate.send(.capture(.captureArea))
        now = Date(timeIntervalSince1970: 1_011)
        #expect(try owner.takePending() == [])
    }

    @Test func inboxRejectsExcessRequestsInsteadOfGrowingWithoutBound() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ApplicationCommandInbox(directory: directory)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        for _ in 0..<16 { try duplicate.send(.capture(.copyFullScreen)) }
        #expect(throws: ApplicationCommandInbox.RoutingError.self) {
            try duplicate.send(.capture(.captureArea))
        }
        #expect(try owner.takePending() == Array(repeating: .capture(.copyFullScreen), count: 16))
    }

    @Test func forwardingAfterOwnerExitsDoesNotLeaveAFutureCapture() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: ApplicationCommandInbox? = try ApplicationCommandInbox(directory: directory)
        #expect(owner?.isOwner == true)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        owner = nil
        #expect(throws: ApplicationCommandInbox.RoutingError.self) {
            try duplicate.send(.capture(.captureArea))
        }
        let replacement = try ApplicationCommandInbox(directory: directory)
        #expect(try replacement.takePending() == [])
    }

    @Test func ownerReceivesColdAndWarmForwardedCommandsOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ApplicationCommandInbox(directory: directory)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        var received: [ApplicationCommand] = []
        try duplicate.send(.capture(.captureArea))
        try owner.startReceiving { received.append($0) }
        #expect(received == [.capture(.captureArea)])
        try duplicate.send(.capture(.copyFullScreen))
        for _ in 0..<40 where received.count < 2 {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(received == [.capture(.captureArea), .capture(.copyFullScreen)])
        #expect(try owner.takePending() == [])
        owner.stopReceiving()
    }

    @Test func duplicateCannotBecomeAnotherCommandReceiver() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ApplicationCommandInbox(directory: directory)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        var received: [ApplicationCommand] = []
        #expect(throws: ApplicationCommandInbox.RoutingError.self) {
            try duplicate.startReceiving { received.append($0) }
        }
        try duplicate.send(.reopen)
        #expect(received.isEmpty)
        #expect(try owner.takePending() == [.reopen])
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
