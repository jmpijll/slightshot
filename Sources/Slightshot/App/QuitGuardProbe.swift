import AppKit

/// Headless check of the quit guard inside a real `SlightshotApplication`.
/// Repeated quit requests arrive while the prompt is open and while a save
/// started from the prompt is running; only the save's own quit may exit.
/// Prints one result line and exits non-zero on any mismatch.
enum QuitGuardProbe {
    static func run() -> Never {
        let app = SlightshotApplication.shared
        let probe = QuitGuardProbeDelegate()
        app.delegate = probe
        app.setActivationPolicy(.prohibited)
        withExtendedLifetime(probe) { app.run() }
        exit(EXIT_FAILURE)
    }
}

private final class QuitGuardProbeDelegate: NSObject, NSApplicationDelegate {
    private var events: [String] = []
    private var saved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        QuitGuard.shared = QuitGuard(
            unsavedWork: { [self] in saved ? nil : .recording(canSave: true) },
            ask: { [self] _ in
                events.append("ask")
                let answer: QuitChoice = events.filter { $0 == "ask" }.count == 1 ? .cancel : .save
                prompt { [self] in
                    events.append("terminate during prompt")
                    NSApp.terminate(nil)
                    // A quit Apple event (logout) asks the delegate before calling terminate.
                    events.append("quit event during prompt")
                    _ = NSApp.delegate?.applicationShouldTerminate?(NSApp)
                }
                return answer
            },
            saveRecording: { [self] in
                events.append("save started")
                after(0.2) { [self] in
                    events.append("terminate during save")
                    NSApp.terminate(nil)
                }
                try? await Task.sleep(for: .milliseconds(600))
                saved = true
                events.append("save finished")
                return true
            },
            copyAnnotations: { false },
            discardRecording: {}
        )
        after(10) { [self] in finish(passed: false, reason: "timed out") }
        after(0.1) { [self] in
            events.append("quit 1")
            NSApp.terminate(nil)
            events.append("quit 1 cancelled")
            after(0.1) { [self] in
                events.append("quit 2")
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let reply = QuitGuard.shared.reply()
        switch reply {
        case .terminateNow: events.append("reply now")
        case .terminateCancel: events.append("reply cancel")
        default: events.append("reply later")
        }
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        let expected = [
            "quit 1", "ask", "terminate during prompt", "quit event during prompt", "reply cancel", "reply cancel",
            "quit 1 cancelled", "quit 2", "ask", "terminate during prompt", "quit event during prompt",
            "reply cancel", "reply cancel", "save started", "terminate during save", "save finished", "reply now",
        ]
        finish(passed: events == expected, reason: events.joined(separator: " | "))
    }

    /// Stands in for `NSAlert.runModal()`: a real modal session ended by a timer.
    private func prompt(during body: @escaping @MainActor @Sendable () -> Void) {
        let panel = NSPanel(contentRect: CGRect(x: -100, y: -100, width: 1, height: 1),
                            styleMask: [.borderless], backing: .buffered, defer: true)
        panel.alphaValue = 0
        after(0.2, body)
        after(0.5) { NSApp.stopModal() }
        NSApp.runModal(for: panel)
    }

    /// Common-mode timers also fire inside modal sessions.
    private func after(_ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable () -> Void) {
        let timer = Timer(timeInterval: seconds, repeats: false) { _ in MainActor.assumeIsolated { body() } }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func finish(passed: Bool, reason: String) {
        print("QUIT-GUARD-PROBE \(passed ? "PASS" : "FAIL"): \(reason)")
        fflush(stdout)
        exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}
