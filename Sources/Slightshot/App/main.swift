import AppKit

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
app.run()
