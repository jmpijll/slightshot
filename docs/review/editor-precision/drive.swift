// Drives the `--redo-review` fixture with real HID mouse events and captures the window after each step.
// Usage: swift drive.swift <output-dir>   (Slightshot must already be running with --redo-review)
import AppKit
import ApplicationServices

let output = CommandLine.arguments.dropFirst().first ?? "."
let content = CGSize(width: 1000, height: 700)

func reviewWindow() -> (id: CGWindowID, bounds: CGRect)? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for info in list where info[kCGWindowName as String] as? String == "Slightshot redo review" {
        guard let id = info[kCGWindowNumber as String] as? CGWindowID,
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict) else { continue }
        return (id, bounds)
    }
    return nil
}

guard AXIsProcessTrusted() else { fatalError("This process needs Accessibility access to post mouse events.") }
var found: (id: CGWindowID, bounds: CGRect)?
for _ in 0..<50 where found == nil {
    found = reviewWindow()
    if found == nil { Thread.sleep(forTimeInterval: 0.2) }
}
guard let window = found else { fatalError("The redo review window is not on screen.") }
let origin = CGPoint(x: window.bounds.minX, y: window.bounds.maxY - content.height)

func global(_ point: CGPoint) -> CGPoint { CGPoint(x: origin.x + point.x, y: origin.y + point.y) }

func post(_ type: CGEventType, at point: CGPoint, flags: CGEventFlags = []) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
    event?.flags = flags
    event?.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.03)
}

func drag(from start: CGPoint, to end: CGPoint, flags: CGEventFlags = [], release: Bool = true) {
    post(.mouseMoved, at: start, flags: flags)
    post(.leftMouseDown, at: start, flags: flags)
    for step in 1...20 {
        let t = CGFloat(step) / 20
        post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
             flags: flags)
    }
    if release { post(.leftMouseUp, at: end, flags: flags) }
    Thread.sleep(forTimeInterval: 0.4)
}

func click(_ point: CGPoint) { drag(from: point, to: point) }

func capture(_ name: String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l\(window.id)", "\(output)/\(name).png"]
    try? task.run()
    task.waitUntilExit()
    print("captured \(name)")
}

/// The toolbar button's centre in global coordinates, found through Accessibility.
func button(_ label: String) -> CGPoint? {
    let running = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.jmpijll.slightshot" }
    for app in running {
        var queue = [AXUIElementCreateApplication(app.processIdentifier)]
        while !queue.isEmpty {
            let element = queue.removeFirst()
            var description: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &description)
            if description as? String == label {
                var position: CFTypeRef?, size: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position)
                AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size)
                var p = CGPoint.zero, s = CGSize.zero
                AXValueGetValue(position as! AXValue, .cgPoint, &p)
                AXValueGetValue(size as! AXValue, .cgSize, &s)
                return CGPoint(x: p.x + s.width / 2, y: p.y + s.height / 2)
            }
            var children: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
            queue += children as? [AXUIElement] ?? []
        }
    }
    return nil
}

Thread.sleep(forTimeInterval: 0.8)
capture("1-fixture")

// A click outside the selection, clear of the toolbar, must keep the selection and every annotation.
click(global(CGPoint(x: 60, y: 660)))
capture("2-after-click-outside")

guard let rectangle = button("Rectangle") else { fatalError("No Rectangle button") }
click(rectangle)
drag(from: global(CGPoint(x: 560, y: 380)), to: global(CGPoint(x: 720, y: 400)), flags: .maskShift)
capture("3-shift-rectangle")

// A drag outside past the threshold starts a new selection; hold it at the window's top-left corner.
drag(from: global(CGPoint(x: 60, y: 660)), to: global(CGPoint(x: 0, y: 0)), release: false)
capture("4-magnifier-corner")
post(.leftMouseUp, at: global(.zero))
