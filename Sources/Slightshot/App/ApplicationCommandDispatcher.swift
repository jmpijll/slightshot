final class ApplicationCommandDispatcher {
    private let isBusy: @MainActor () -> Bool
    private let capture: @MainActor (LaunchCommand) -> Void
    private let reopen: @MainActor () -> Void

    init(isBusy: @escaping @MainActor () -> Bool,
         capture: @escaping @MainActor (LaunchCommand) -> Void, reopen: @escaping @MainActor () -> Void) {
        self.isBusy = isBusy
        self.capture = capture
        self.reopen = reopen
    }

    func run(_ command: ApplicationCommand) {
        guard !isBusy() else { return }
        switch command {
        case .capture(let action): capture(action)
        case .reopen: reopen()
        }
    }
}
