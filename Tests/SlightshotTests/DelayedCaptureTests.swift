import Foundation
import Testing
@testable import Slightshot

@MainActor
struct DelayedCaptureTests {
    @Test func cancellationReplacementDeadlineAndBusyOwnership() {
        var time: TimeInterval = 100
        var busy = false
        var callbacks: [@MainActor () -> Void] = []
        var invalidated = 0
        var captures = 0
        var visible = false
        var seconds = 0
        let controller = DelayedCaptureController(now: { time }, schedule: { _, callback in
            callbacks.append(callback)
            return { invalidated += 1 }
        }, isBusy: { busy }, show: { seconds = $0; visible = true }, hide: { visible = false }, capture: {
            #expect(!visible)
            captures += 1
            busy = true
        })
        #expect(controller.start())
        #expect(seconds == 5 && captures == 0)
        let cancelled = callbacks.removeFirst()
        controller.cancel()
        time = 110
        cancelled()
        #expect(captures == 0 && !controller.isPending && !visible && invalidated == 1)

        #expect(controller.start())
        let replaced = callbacks.removeFirst()
        time = 112
        #expect(controller.start())
        replaced()
        #expect(captures == 0 && callbacks.count == 1)
        time = 116.999
        callbacks.removeFirst()()
        #expect(captures == 0 && seconds == 1)
        time = 117
        let due = callbacks.removeFirst()
        due()
        due() // A duplicate queued delivery must not open a second editor.
        #expect(captures == 1 && !controller.isPending && !visible)
        #expect(!controller.start())
        busy = false
        #expect(controller.start())
        busy = true // An editor or recording acquired the application meanwhile.
        time = 122
        callbacks.removeFirst()()
        #expect(captures == 1 && !controller.isPending && !visible)

        busy = false
        #expect(controller.start())
        let terminated = callbacks.removeFirst()
        controller.cancel() // Quit/ordinary capture invalidate the same owner.
        time = 200
        terminated()
        #expect(captures == 1 && !controller.isPending)
    }
}
