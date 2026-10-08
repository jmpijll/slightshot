import Foundation

nonisolated enum LaunchCommand: String, Codable, Sendable {
    case captureArea = "--capture-area"
    case saveFullScreen = "--capture-full"
    case copyFullScreen = "--copy-full"

    init?(arguments: [String]) {
        guard let match = arguments.dropFirst().compactMap({ LaunchCommand(rawValue: $0) }).first else { return nil }
        self = match
    }

    init?(url: URL) {
        // Match the whole route, including its spelling. URLComponents would
        // otherwise normalize encoded hosts and overlook empty query/fragment suffixes.
        switch url.absoluteString {
        case "slightshot://capture-area": self = .captureArea
        case "slightshot://capture-full": self = .saveFullScreen
        case "slightshot://copy-full": self = .copyFullScreen
        default: return nil
        }
    }
}

nonisolated enum ApplicationCommand: Codable, Equatable, Sendable {
    case capture(LaunchCommand)
    case reopen
}
