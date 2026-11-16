// Hands a file to an app the way a sibling does (SIBLINGS.md §6): NSWorkspace opens the file
// with that app, in a new instance, so the file arrives as an "open documents" event at launch.
//   swift scripts/handover.swift <app> <file> [launch arguments…]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: handover <app> <file> [arguments…]"); exit(2) }
let configuration = NSWorkspace.OpenConfiguration()
configuration.createsNewApplicationInstance = true
configuration.arguments = Array(args.dropFirst(3))
let done = DispatchSemaphore(value: 0)
var failure: Error?
NSWorkspace.shared.open([URL(fileURLWithPath: args[2])], withApplicationAt: URL(fileURLWithPath: args[1]), configuration: configuration) { _, error in
    failure = error
    done.signal()
}
done.wait()
if let failure { print("handover failed: \(failure.localizedDescription)"); exit(1) }
