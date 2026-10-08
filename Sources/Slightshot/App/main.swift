import AppKit

// CI verifies framework linkage without claiming ownership or requesting permissions.
if CommandLine.arguments.contains("--verify-runtime-linkage") {
    print("Slightshot runtime linkage verified")
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--redo-review") {
    let app = NSApplication.shared
    let review = RedoReview()
    app.delegate = review
    app.setActivationPolicy(.regular)
    withExtendedLifetime(review) { app.run() }
    exit(EXIT_SUCCESS)
}

if CommandLine.arguments.contains("--delayed-review") {
    let app = NSApplication.shared
    let evidenceFlag = CommandLine.arguments.firstIndex(of: "--delayed-review-evidence")
    let evidenceDirectory = evidenceFlag.flatMap { index in
        CommandLine.arguments.indices.contains(index + 1)
            ? URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true) : nil
    }
    let review = DelayedCaptureReview(evidenceDirectory: evidenceDirectory)
    app.delegate = review
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(review) { app.run() }
    exit(EXIT_SUCCESS)
}

let commandInbox: ApplicationCommandInbox
do {
    commandInbox = try ApplicationCommandInbox(directory: ApplicationCommandInbox.userDirectory())
} catch {
    Log.app.error("Slightshot could not claim command ownership: \(error.localizedDescription, privacy: .public)")
    exit(EXIT_FAILURE)
}

let app = NSApplication.shared
let delegate = AppDelegate(launchCommand: LaunchCommand(arguments: CommandLine.arguments), inbox: commandInbox)
app.delegate = delegate
app.setActivationPolicy(.accessory)
withExtendedLifetime(delegate) { app.run() }
