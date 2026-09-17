import OSLog

nonisolated enum Log {
    private static let subsystem = "com.jmpijll.slightshot"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let overlay = Logger(subsystem: subsystem, category: "overlay")
    static let output = Logger(subsystem: subsystem, category: "output")
    static let hotkeys = Logger(subsystem: subsystem, category: "hotkeys")
    static let updater = Logger(subsystem: subsystem, category: "updater")
}
