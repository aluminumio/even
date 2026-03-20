import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: even text \"message\"\n", stderr)
    fputs("       even ask \"question?\" [timeout_sec]\n", stderr)
    exit(2)
}

let cmd = args[1]
let ble = GlassesBLE()

switch cmd {
case "text":
    let text = args[2...].joined(separator: " ")
    exit(ble.send(text))
case "ask":
    // Last arg is timeout if it's a number
    var textArgs = args[2...]
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
