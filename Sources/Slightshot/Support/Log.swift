import Foundation
import OSLog

nonisolated enum Log {
    /// `SLIGHTSHOT_DEBUG=1` mirrors diagnostics to stderr, which is far easier
    /// to read than Console.app while working on the capture path.
    static let isDebug = ProcessInfo.processInfo.environment["SLIGHTSHOT_DEBUG"] == "1"

    static func debug(_ message: @autoclosure () -> String, _ logger: Logger = Log.app) {
        let text = message()
        logger.debug("\(text, privacy: .public)")
        guard isDebug else { return }
        FileHandle.standardError.write(Data("[slightshot] \(text)\n".utf8))
    }

    private static let subsystem = "com.jmpijll.slightshot"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let output = Logger(subsystem: subsystem, category: "output")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let updater = Logger(subsystem: subsystem, category: "updater")
}
