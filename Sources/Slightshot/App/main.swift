import AppKit

let app = NSApplication.shared
let delegate = AppDelegate(launchCommand: LaunchCommand(arguments: CommandLine.arguments))
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
