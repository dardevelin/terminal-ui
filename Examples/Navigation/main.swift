import Foundation
import Observation
import TerminalUI

// A drill-down that ends in the settings screen — the composition NavigationStack
// exists for, and the one the parity epic's acceptance names: a settings screen
// reachable *through* navigation, since that is what real apps do.
//
// State lives in an `@Observable` class because the links capture bindings, and
// `@TerminalState` does not survive a handler closure. The path is the model:
// a NavigationLink pushes onto it, Esc pops it, and the stack re-renders from
// whatever is on top.

enum Screen: Hashable {
    case section(String)
    case settings
}

enum Theme: String, CaseIterable, Hashable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@Observable
final class AppModel {
    var path: [Screen] = []
    var theme: Theme = .dark
    var telemetry = false
    var editor = "vim"
}

nonisolated(unsafe) let model = AppModel()

struct RootScreen: TerminalView {
    let model: AppModel

    var body: some TerminalView {
        VStack {
            Text("Choose a destination").foreground(.gray)
            NavigationLink(value: Screen.section("Account")) { Text("Account") }
            NavigationLink(value: Screen.section("Network")) { Text("Network") }
            NavigationLink(value: Screen.settings) { Text("Settings") }
        }
        .navigationTitle("Home")
    }
}

/// The settings screen from the Form work, reached through navigation. This is
/// the composition the epic's acceptance calls for.
struct SettingsScreen: TerminalView {
    let model: AppModel

    var body: some TerminalView {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: Binding(
                    get: { model.theme }, set: { model.theme = $0 }
                )) {
                    ForEach(Theme.allCases) { theme in Text(theme.title).tag(theme) }
                }
                .pickerStyle(.segmented)
                Toggle("Telemetry", isOn: Binding(
                    get: { model.telemetry }, set: { model.telemetry = $0 }
                ))
            }
            Section("Editor") {
                LabeledContent("Program", value: model.editor)
            }
        }
        .navigationTitle("Settings")
    }
}

struct App: TerminalView {
    let model: AppModel

    var body: some TerminalView {
        NavigationStack(path: Binding(
            get: { model.path }, set: { model.path = $0 }
        )) {
            RootScreen(model: model)
        }
        .navigationDestination(for: Screen.self) { screen in
            switch screen {
            case .section(let name):
                VStack {
                    Text("Inside \(name)").foreground(.gray)
                    Text("Esc goes back").foreground(.gray)
                }
                .navigationTitle(name)
            case .settings:
                SettingsScreen(model: model)
            }
        }
    }
}

@main
struct NavigationApp: TerminalAppProtocol {
    static var renderMode: RenderMode { .onDemand }

    static func content() -> some TerminalView {
        App(model: model)
    }

    static func onEvent(_ event: TerminalEvent) -> Bool {
        // Ctrl+C quits; Esc is left to the navigation stack to pop.
        if case .key(let key) = event,
           key.key == .character("c"), key.modifiers.contains(.ctrl) {
            return false
        }
        return true
    }
}
