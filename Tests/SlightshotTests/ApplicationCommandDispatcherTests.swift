import Testing
@testable import Slightshot

@MainActor
struct ApplicationCommandDispatcherTests {
    @Test(arguments: [LaunchCommand.captureArea, .saveFullScreen, .copyFullScreen])
    func idleCaptureRunsTheRequestedAction(_ command: LaunchCommand) {
        var actions: [LaunchCommand] = []
        var reopens = 0
        let dispatcher = ApplicationCommandDispatcher(
            isBusy: { false }, capture: { actions.append($0) }, reopen: { reopens += 1 }
        )
        dispatcher.run(.capture(command))
        #expect(actions == [command])
        #expect(reopens == 0)
    }

    @Test func busySessionRejectsCommandsWithoutReplayingThemLater() {
        let state = BusyState()
        var actions: [LaunchCommand] = []
        var reopens = 0
        let dispatcher = ApplicationCommandDispatcher(
            isBusy: { state.busy }, capture: { actions.append($0) }, reopen: { reopens += 1 }
        )
        dispatcher.run(.capture(.captureArea))
        dispatcher.run(.capture(.saveFullScreen))
        dispatcher.run(.capture(.copyFullScreen))
        dispatcher.run(.reopen)
        #expect(actions.isEmpty)
        #expect(reopens == 0)
        state.busy = false
        dispatcher.run(.capture(.captureArea))
        #expect(actions == [.captureArea])
        #expect(reopens == 0)
    }

    @Test func idleReopenShowsPreferencesWithoutCapturing() {
        var actions: [LaunchCommand] = []
        var reopens = 0
        let dispatcher = ApplicationCommandDispatcher(
            isBusy: { false }, capture: { actions.append($0) }, reopen: { reopens += 1 }
        )
        dispatcher.run(.reopen)
        #expect(actions.isEmpty)
        #expect(reopens == 1)
    }

    private final class BusyState {
        var busy = true
    }
}
