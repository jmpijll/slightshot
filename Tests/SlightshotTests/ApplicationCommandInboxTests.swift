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
        var drops: [Drop] = []
        let owner = try ApplicationCommandInbox(directory: directory, now: { now },
                                                reportExpired: { drops.append(Drop($0, $1)) })
        let duplicate = try ApplicationCommandInbox(directory: directory, now: { now })
        try duplicate.send(.capture(.captureArea))
        #expect(try owner.takePending() == [.capture(.captureArea)])
        try duplicate.send(.capture(.captureArea))
        now = Date(timeIntervalSince1970: 1_011)
        #expect(try owner.takePending() == [])
        #expect(drops == [Drop(.capture(.captureArea), 11)])
    }

    @Test func forwarderReportsStaleRequestsItDiscards() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000)
        var drops: [Drop] = []
        let owner = try ApplicationCommandInbox(directory: directory, now: { now })
        let duplicate = try ApplicationCommandInbox(directory: directory, now: { now },
                                                    reportExpired: { drops.append(Drop($0, $1)) })
        try duplicate.send(.capture(.saveFullScreen))
        now = Date(timeIntervalSince1970: 1_012)
        try duplicate.send(.reopen)
        #expect(drops == [Drop(.capture(.saveFullScreen), 12)])
        #expect(try owner.takePending() == [.reopen])
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

    // Other suites share the main actor and can stall it past the 10 s expiry under load,
    // so freeze the clock and wait for the delivery itself instead of a time budget.
    @Test(.timeLimit(.minutes(1)))
    func ownerReceivesColdAndWarmForwardedCommandsOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = Date(timeIntervalSince1970: 1_000)
        let owner = try ApplicationCommandInbox(directory: directory, now: { now })
        let duplicate = try ApplicationCommandInbox(directory: directory, now: { now })
        let (received, deliver) = AsyncStream.makeStream(of: ApplicationCommand.self)
        var deliveries = received.makeAsyncIterator()
        try duplicate.send(.capture(.captureArea))
        try owner.startReceiving { deliver.yield($0) }
        #expect(await deliveries.next() == .capture(.captureArea))
        try duplicate.send(.capture(.copyFullScreen))
        #expect(await deliveries.next() == .capture(.copyFullScreen))
        #expect(try owner.takePending() == [])
        owner.stopReceiving()
        deliver.finish()
        #expect(await deliveries.next() == nil)
    }

    // The clock advances between the forward and the owner's drain, as when the owner's
    // main thread is busy encoding or writing a capture.
    @Test(.timeLimit(.minutes(1)))
    func ownerStallWithinExpiryStillDeliversOnce() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000)
        var drops: [Drop] = []
        let owner = try ApplicationCommandInbox(directory: directory, now: { now },
                                                reportExpired: { drops.append(Drop($0, $1)) })
        let duplicate = try ApplicationCommandInbox(directory: directory, now: { now })
        let (received, deliver) = AsyncStream.makeStream(of: ApplicationCommand.self)
        var deliveries = received.makeAsyncIterator()
        try owner.startReceiving { deliver.yield($0) }
        try duplicate.send(.capture(.captureArea))
        now = Date(timeIntervalSince1970: 1_010)
        #expect(await deliveries.next() == .capture(.captureArea))
        #expect(try owner.takePending() == [])
        owner.stopReceiving()
        deliver.finish()
        #expect(await deliveries.next() == nil)
        #expect(drops.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func ownerStallBeyondExpiryDropsAndReportsTheCommand() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = Date(timeIntervalSince1970: 1_000)
        let (dropped, reportDrop) = AsyncStream.makeStream(of: Drop.self)
        var drops = dropped.makeAsyncIterator()
        let owner = try ApplicationCommandInbox(directory: directory, now: { now },
                                                reportExpired: { reportDrop.yield(Drop($0, $1)) })
        let duplicate = try ApplicationCommandInbox(directory: directory, now: { now })
        let (received, deliver) = AsyncStream.makeStream(of: ApplicationCommand.self)
        var deliveries = received.makeAsyncIterator()
        try owner.startReceiving { deliver.yield($0) }
        try duplicate.send(.capture(.captureArea))
        now = Date(timeIntervalSince1970: 1_011)
        #expect(await drops.next() == Drop(.capture(.captureArea), 11))
        try duplicate.send(.reopen)
        #expect(await deliveries.next() == .reopen)
        owner.stopReceiving()
        deliver.finish()
        reportDrop.finish()
        #expect(await deliveries.next() == nil)
        #expect(await drops.next() == nil)
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

    private struct Drop: Equatable, Sendable {
        let command: ApplicationCommand
        let age: TimeInterval

        init(_ command: ApplicationCommand, _ age: TimeInterval) {
            self.command = command
            self.age = age
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }
}
