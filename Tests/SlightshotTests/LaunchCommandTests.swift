import Foundation
import Testing
@testable import Slightshot

struct LaunchCommandTests {
    // Dropping an action or accepting extra URL components would break scripting.
    @Test(arguments: [
        ("slightshot://capture-area", LaunchCommand.captureArea),
        ("slightshot://capture-full", LaunchCommand.saveFullScreen),
        ("slightshot://copy-full", LaunchCommand.copyFullScreen),
    ])
    func acceptsOnlyDocumentedRoutes(_ route: String, _ expected: LaunchCommand) throws {
        #expect(LaunchCommand(url: try #require(URL(string: route))) == expected)
    }

    @Test(arguments: [
        "https://capture-area", "slightshot:copy-full", "slightshot:///copy-full",
        "slightshot://unknown", "slightshot://copy-full/", "slightshot://copy-full/path",
        "slightshot://user@copy-full", "slightshot://user:password@copy-full",
        "slightshot://copy-full:12", "slightshot://copy-full?", "slightshot://copy-full?save=true",
        "slightshot://copy-full#", "slightshot://copy-full#capture-area",
        "slightshot://%63opy-full", "slightshot://copy-full%20", "slightshot://COPY-FULL",
    ])
    func rejectsUnknownOrMalformedRoutes(_ route: String) throws {
        #expect(LaunchCommand(url: try #require(URL(string: route))) == nil)
    }

    @Test func preservesColdStartArguments() {
        #expect(LaunchCommand(arguments: ["Slightshot", "--capture-area"]) == .captureArea)
        #expect(LaunchCommand(arguments: ["Slightshot", "--capture-full"]) == .saveFullScreen)
        #expect(LaunchCommand(arguments: ["Slightshot", "--copy-full"]) == .copyFullScreen)
        #expect(LaunchCommand(arguments: ["Slightshot", "--unknown"]) == nil)
        #expect(LaunchCommand(arguments: ["--copy-full"]) == nil)
    }
}
