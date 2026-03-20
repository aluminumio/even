import Foundation

var rawArgs = Array(CommandLine.arguments.dropFirst())
let verbose = rawArgs.contains("-v") || rawArgs.contains("--verbose")
rawArgs.removeAll { $0 == "-v" || $0 == "--verbose" }

guard rawArgs.count >= 2 else {
    fputs("Usage: even [-v] text \"message\"\n", stderr)
    fputs("       even [-v] ask \"question?\" [timeout_sec]\n", stderr)
    exit(2)
}

let cmd = rawArgs[0]
let ble = GlassesBLE(verbose: verbose)

switch cmd {
case "text":
    let text = rawArgs[1...].joined(separator: " ")
    exit(ble.send(text))
case "ask":
    var textArgs = rawArgs[1...]
    var timeout: TimeInterval = 30
    if textArgs.count > 1, let t = TimeInterval(textArgs.last!) {
        timeout = t
        textArgs = textArgs.dropLast()
    }
    let text = textArgs.joined(separator: " ")
    let result = ble.ask(text, timeout: timeout)
    print(result == 0 ? "yes" : "no")
    exit(result)
default:
    fputs("Unknown command: \(cmd)\n", stderr)
    exit(2)
}
