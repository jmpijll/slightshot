// Two-process delivery probe for ApplicationCommandInbox, built from the shipped sources by
// forward-probe.sh. The owner process receives on its main queue exactly like the app; the
// sender process forwards a numbered pattern. The owner reports lost, reordered or repeated
// commands. An optional stall blocks the owner's main thread while the sender forwards, as
// synchronous encoding or file writes in the app would; the owner then reports what arrived.
import Foundation

let arguments = CommandLine.arguments
let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let total = Int(arguments[3])!
let pattern: [ApplicationCommand] = [.capture(.captureArea), .capture(.saveFullScreen),
                                     .capture(.copyFullScreen), .reopen]
let inbox = try ApplicationCommandInbox(directory: directory)

switch arguments[1] {
case "owner":
    precondition(inbox.isOwner)
    var received: [ApplicationCommand] = []
    let start = Date()
    try inbox.startReceiving { command in
        received.append(command)
        guard received.count >= total else { return }
        let expected = (0..<total).map { pattern[$0 % pattern.count] }
        let verdict = received == expected ? "OK" : "MISMATCH"
        print("OWNER \(verdict) delivered=\(received.count)/\(total) seconds=\(Date().timeIntervalSince(start))")
        exit(received == expected ? 0 : 1)
    }
    print("READY")
    fflush(stdout)
    if let stall = arguments.dropFirst(4).first.flatMap(Double.init) {
        usleep(useconds_t(stall * 1_000_000))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            print("OWNER STALLED \(stall) s delivered=\(received.count)/\(total)")
            exit(received.count == total ? 0 : 3)
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
        print("OWNER LOST delivered=\(received.count)/\(total)")
        exit(2)
    }
    dispatchMain()
case "sender":
    precondition(!inbox.isOwner)
    var full = 0
    for index in 0..<total {
        while true {
            do {
                try inbox.send(pattern[index % pattern.count])
                break
            } catch ApplicationCommandInbox.RoutingError.inboxFull {
                full += 1
                usleep(1_000)
            }
        }
    }
    print("SENDER sent=\(total) inboxFullRetries=\(full)")
default:
    fatalError("usage: forward-probe owner|sender <directory> <count> [owner stall seconds]")
}
