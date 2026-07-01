import Foundation

var rawArgs = Array(CommandLine.arguments.dropFirst())
let verbose = rawArgs.contains("-v") || rawArgs.contains("--verbose") || rawArgs.contains("--debug")
rawArgs.removeAll { $0 == "-v" || $0 == "--verbose" || $0 == "--debug" }

guard rawArgs.count >= 1 else {
    fputs("Usage: even [-v] text \"message\"\n", stderr)
    fputs("       even [-v] ask \"question?\" [timeout_sec]\n", stderr)
    fputs("       even [-v] notify \"title\" \"message\" [timeout_sec]\n", stderr)
    fputs("       even [-v] dump [seconds]\n", stderr)
    fputs("       even [-v] lab <ai|nus|bare|hub|conv> [\"text\"] [duration] [--mic]\n", stderr)
    fputs("       even [-v] bond [duration]\n", stderr)
    exit(2)
}

let cmd = rawArgs[0]

if cmd == "version" || cmd == "--version" {
    print("even 0.7.0")
    exit(0)
}

let ble = GlassesBLE(verbose: verbose)

switch cmd {
case "text":
    guard rawArgs.count >= 2 else {
        fputs("Usage: even text \"message\"\n", stderr)
        exit(2)
    }
    let text = rawArgs[1...].joined(separator: " ")
    exit(ble.send(text))
case "ask":
    guard rawArgs.count >= 2 else {
        fputs("Usage: even ask \"question?\" [timeout_sec]\n", stderr)
        exit(2)
    }
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
case "notify":
    guard rawArgs.count >= 3 else {
        fputs("Usage: even notify \"title\" \"message\" [timeout_sec]\n", stderr)
        exit(2)
    }
    let title = rawArgs[1]
    var notifyArgs = Array(rawArgs[2...])
    var notifyTimeout: TimeInterval = 30
    if notifyArgs.count > 1, let t = TimeInterval(notifyArgs.last!) {
        notifyTimeout = t
        notifyArgs = Array(notifyArgs.dropLast())
    }
    let message = notifyArgs.joined(separator: " ")
    let result = ble.notify(title: title, message: message, timeout: notifyTimeout)
    print(result == 0 ? "yes" : "no")
    exit(result)
case "dump":
    let duration = rawArgs.count >= 2 ? TimeInterval(rawArgs[1]) ?? 30 : 30
    exit(ble.dump(duration: duration))
case "bond":
    let bondTimeout: TimeInterval = rawArgs.count >= 2 ? TimeInterval(rawArgs[1]) ?? 30 : 30
    exit(ble.bond(timeout: bondTimeout))
case "lab":
    guard rawArgs.count >= 2 else {
        fputs("Usage: even lab <ai|nus|bare|conv> [\"text\"] [duration] [--mic]\n", stderr)
        exit(2)
    }
    let display = rawArgs[1]
    let mic = rawArgs.contains("--mic")
    var labArgs = Array(rawArgs[2...].filter { $0 != "--mic" })
    var labDuration: TimeInterval = 30
    if labArgs.count > 0, let d = TimeInterval(labArgs.last!) {
        labDuration = d
        labArgs = Array(labArgs.dropLast())
    }
    let labText = labArgs.joined(separator: " ")
    exit(ble.lab(display: display, text: labText, mic: mic, duration: labDuration))
default:
    fputs("Unknown command: \(cmd)\n", stderr)
    exit(2)
}
