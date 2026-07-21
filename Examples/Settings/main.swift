import Foundation
import Observation
import TerminalUI

// A settings screen — the composite that `Picker` existed to make buildable.
//
// The point of this example is idiom, not feature count: a picker, a toggle
// and a text field sit side by side, Tab moves between them, and each one is
// driven by a binding into the same `@Observable` model. If any of those needed
// a special case to work next to the others, this is where it would show.
//
// State lives in an `@Observable` class rather than `@TerminalState` because
// the controls' handlers capture bindings, and `@TerminalState` does not
// survive a handler closure — the projected `$binding` must be taken during
// body evaluation.

enum Theme: String, CaseIterable, Hashable, Identifiable {
    case light, dark, auto
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum Density: String, CaseIterable, Hashable, Identifiable {
    case compact, cozy, comfortable
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

@Observable
final class SettingsModel {
    var theme: Theme = .dark
    var density: Density = .cozy
    var editor: String = "vim"
    var telemetry: Bool = false
    var autosave: Bool = true
}

/// Top-level singleton — Storybook / Demo / GitClient pattern. Safe because
/// all reads happen on @MainActor at body-eval time.
nonisolated(unsafe) let model = SettingsModel()

struct SettingsScreen: TerminalView {
    let model: SettingsModel

    var body: some TerminalView {
        VStack {
            Text(" Settings ").bold()
            Divider()

            // Segmented reads as a row of mutually exclusive choices — the
            // right shape for a short, flat option set.
            Picker("Theme   ", selection: Binding(
                get: { model.theme }, set: { model.theme = $0 }
            )) {
                ForEach(Theme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }
            .pickerStyle(.segmented)

            // The same option set, collapsed. Dropdown suits a settings row
            // where the current value matters more than the alternatives.
            Picker("Density ", selection: Binding(
                get: { model.density }, set: { model.density = $0 }
            )) {
                ForEach(Density.allCases) { density in
                    Text(density.title).tag(density)
                }
            }
            .pickerStyle(.dropdown)

            Divider()

            Toggle("Telemetry", isOn: Binding(
                get: { model.telemetry }, set: { model.telemetry = $0 }
            ))
            Toggle("Autosave ", isOn: Binding(
                get: { model.autosave }, set: { model.autosave = $0 }
            ))

            Divider()

            HStack {
                Text("Editor   ")
                TextInput(text: Binding(
                    get: { model.editor }, set: { model.editor = $0 }
                ))
            }

            Divider()
            summary
            Text("Tab / Shift-Tab move · arrows choose · Ctrl-C quits")
                .foreground(.gray)
        }
        .padding(1)
    }

    /// Echoes the live model so the example proves the bindings actually
    /// commit, rather than only that the controls render.
    private var summary: some TerminalView {
        VStack {
            Text("theme=\(model.theme.rawValue)  density=\(model.density.rawValue)")
                .foreground(.cyan)
            Text("editor=\(model.editor)  telemetry=\(model.telemetry)  autosave=\(model.autosave)")
                .foreground(.cyan)
        }
    }
}

@main
struct SettingsApp: TerminalAppProtocol {
    /// A settings screen is idle between keypresses, so it renders on demand
    /// and costs nothing while the user reads it.
    static var renderMode: RenderMode { .onDemand }

    static func content() -> some TerminalView {
        SettingsScreen(model: model)
    }

    static func onEvent(_ event: TerminalEvent) -> Bool {
        // The framework default quits on bare `q` and Escape, both of which a
        // settings screen needs: `q` is a legitimate character for the editor
        // field, and Escape closes an open dropdown.
        if case .key(let key) = event,
           key.key == .character("c"), key.modifiers.contains(.ctrl) {
            return false
        }
        return true
    }
}
