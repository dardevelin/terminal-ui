# Getting Started

Set up TerminalUI in a new Swift package and write your first TUI.

## Requirements

- Swift 6.2 or newer
- macOS 15+ or Linux

## Install

Add TerminalUI to your `Package.swift`:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "YourApp",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/dardevelin/terminal-ui", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "YourApp",
            dependencies: [
                .product(name: "TerminalUI", package: "terminal-ui"),
            ]
        ),
    ]
)
```

## Your first TUI

Create `Sources/YourApp/main.swift`:

```swift
import Observation
import TerminalUI

@Observable
final class Counter {
    var value = 0
}

@main
struct CounterApp: TerminalAppProtocol {
    static let state = Counter()

    static func onEvent(_ event: TerminalEvent) -> Bool {
        if case .key(let k) = event {
            switch k.key {
            case .character("+"): state.value += 1
            case .character("-"): state.value -= 1
            case .character("q"), .escape: return false  // quit
            default: break
            }
        }
        return true
    }

    static func content() -> some TerminalView {
        VStack {
            Text("Counter").bold()
            Divider()
            Text("value = \(state.value)")
            Text("  +/-: change   q: quit").foreground(.gray)
        }
    }
}
```

Run it:

```bash
swift run YourApp
```

Press `+`, `-`, `q`. That's the full programming model.

## What's next

- Explore the full API catalog via `swift run Storybook` in the TerminalUI repo
  (35 pages, one per component, with live previews).
- Learn the framework's architecture: <doc:ArchitecturalModels>, <doc:AttributeGraph>, <doc:Layering>.
- Look at `Examples/Demo` in the TerminalUI repo for a 12-tab feature showcase.
