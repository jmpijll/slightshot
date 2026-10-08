import AppKit
import Testing
@testable import Slightshot

@MainActor
struct AppDelegateCommandTests {
    @Test func coldURLIsQueuedUntilTheOwnerIsReady() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = try ApplicationCommandInbox(directory: directory)
        let delegate = AppDelegate(launchCommand: nil, inbox: inbox)
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "slightshot://capture-full"))])
        #expect(try inbox.takePending() == [.capture(.saveFullScreen)])
    }

    @Test func anotherBundleForwardsOnlyValidURLsToTheOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let owner = try ApplicationCommandInbox(directory: directory)
        let duplicate = try ApplicationCommandInbox(directory: directory)
        let delegate = AppDelegate(launchCommand: nil, inbox: duplicate)
        let urls = ["slightshot://copy-full?unexpected=true", "slightshot://copy-full", "slightshot://unknown"]
        delegate.application(NSApplication.shared, open: urls.compactMap(URL.init(string:)))
        #expect(try owner.takePending() == [.capture(.copyFullScreen)])
        #expect(try duplicate.takePending() == [])
    }
}
