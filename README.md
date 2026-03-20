# even

CLI to send text to [Even Realities G2](https://evenrealities.com) smart glasses over Bluetooth.

## Install

```sh
brew install usiegj00/tap/even
```

## Usage

**Display text:**

```sh
even text "Hello from your Mac"
```

**Interactive prompt (press+hold touchpad = yes, timeout = no):**

```sh
even ask "Deploy to production?" 30
# prints "yes" or "no", exits 0 or 1
```

Pipeable:

```sh
even ask "Proceed?" 20 && ./deploy.sh
```

## How it works

Connects to G2 glasses via Bluetooth Low Energy, authenticates using the Even UART Service (EUS) protocol, and displays text through the AI display mode. The `ask` command enters an interactive AI session on the right eye and listens for touchpad press events.

## Requirements

- macOS 12+
- Even Realities G2 glasses (powered on and in range)
- Bluetooth permission for Terminal

## Build from source

```sh
git clone https://github.com/usiegj00/even.git
cd even
swift build -c release
# binary at .build/release/even
```

## License

MIT
