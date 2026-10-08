import Foundation

/// Main-thread ownership of one countdown. A generation also protects against
/// callbacks already queued when their timer is invalidated.
final class DelayedCaptureController {
    typealias Scheduler = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let now: () -> TimeInterval
    private let schedule: Scheduler
    private let isBusy: () -> Bool
    private let show: (Int) -> Void
    private let hide: () -> Void
    private let capture: () -> Void
    private var cancellation: (() -> Void)?
    private var generation = 0
    private var deadline: TimeInterval?

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Scheduler = DelayedCaptureController.scheduleTimer,
         isBusy: @escaping () -> Bool, show: @escaping (Int) -> Void,
         hide: @escaping () -> Void, capture: @escaping () -> Void) {
        self.now = now
        self.schedule = schedule
        self.isBusy = isBusy
        self.show = show
        self.hide = hide
        self.capture = capture
    }

    var isPending: Bool { deadline != nil }

    @discardableResult
    func start() -> Bool {
        guard !isBusy() else { return false }
        cancel()
        deadline = now() + 5
        show(5)
        arm(generation)
        return true
    }

    func cancel() {
        generation += 1
        deadline = nil
        cancellation?()
        cancellation = nil
        hide()
    }

    private func arm(_ token: Int) {
        cancellation = schedule(0.1) { [weak self] in self?.tick(token) }
    }

    private func tick(_ token: Int) {
        guard generation == token, let deadline else { return }
        cancellation = nil
        let remaining = deadline - now()
        if remaining > 0 {
            show(Int(ceil(remaining)))
            arm(token)
        } else {
            cancel()
            if !isBusy() { capture() }
        }
    }

    private static func scheduleTimer(_ delay: TimeInterval, callback: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { callback() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
