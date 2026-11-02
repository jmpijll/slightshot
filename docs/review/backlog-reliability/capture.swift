import AppKit

// Render the recorded validation output in a native window, then capture it.
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 780),
                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
window.title = "Slightshot validation output"
window.isReleasedWhenClosed = false
let text = NSTextView(frame: NSRect(x: 22, y: 18, width: 1116, height: 740))
text.isEditable = false
text.font = NSFont.monospacedSystemFont(ofSize: 15, weight: .regular)
text.textColor = .black
text.backgroundColor = .white
text.string = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
window.contentView?.addSubview(text)
window.backgroundColor = .white
window.center()
window.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
    let capture = Process()
    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), CommandLine.arguments[2]]
    try! capture.run()
    capture.waitUntilExit()
    app.terminate(nil)
}
app.run()
