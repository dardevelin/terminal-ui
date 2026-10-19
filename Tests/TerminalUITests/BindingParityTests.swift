import Testing
@testable import TerminalUI

// A child view that edits a value it does not own is written, in SwiftUI,
// with `@Binding var value`, handed `$value` or `$model.field`, or handed
// `.constant(x)` when nothing should change. None of that existed: every
// binding was a hand-written get/set pair. These pin the SwiftUI shapes.

private struct Settings {
    var isMuted = false
    var volume = Volume()
}

private struct Volume {
    var level = 3
}

/// Edits a value it does not own, through `@Binding`.
private struct VolumeEditor {
    @Binding var settings: Settings

    func mute() { settings.isMuted = true }
}

/// The same, built by a custom initialiser the way SwiftUI code writes it.
private struct LevelEditor {
    @Binding var level: Int

    init(level: Binding<Int>) {
        self._level = level
    }

    func raise() { level += 1 }
}

@Suite("Binding has SwiftUI's shape")
@MainActor
struct BindingParityTests {

    @Test func aConstantReadsItsValueAndIgnoresWrites() {
        let binding = Binding.constant(7)
        binding.wrappedValue = 9
        #expect(binding.wrappedValue == 7)
    }

    @Test func aPropertyOfABoundValueIsItselfBindable() {
        var storage = Settings()
        let settings = Binding(get: { storage }, set: { storage = $0 })
        let muted = settings.isMuted
        #expect(muted.wrappedValue == false)
        muted.wrappedValue = true
        #expect(storage.isMuted)
    }

    @Test func derivedBindingsNest() {
        var storage = Settings()
        let settings = Binding(get: { storage }, set: { storage = $0 })
        settings.volume.level.wrappedValue = 9
        #expect(storage.volume.level == 9)
        #expect(storage.isMuted == false, "a write to one field leaves the others alone")
    }

    @Test func aBindingPropertyWritesThroughToItsOwner() {
        var storage = Settings()
        let editor = VolumeEditor(settings: Binding(get: { storage }, set: { storage = $0 }))
        editor.mute()
        #expect(storage.isMuted)
        // `$settings` on the wrapper is the binding, ready to pass further down.
        editor.$settings.volume.level.wrappedValue = 5
        #expect(storage.volume.level == 5)
    }

    @Test func aCustomInitialiserAssignsTheBackingBinding() {
        var level = 1
        let editor = LevelEditor(level: Binding(get: { level }, set: { level = $0 }))
        editor.raise()
        #expect(level == 2)
    }

    @Test func projectedValueInitialisationMatchesSwiftUI() {
        var level = 4
        let source = Binding(get: { level }, set: { level = $0 })
        let copy = Binding(projectedValue: source)
        copy.wrappedValue = 6
        #expect(level == 6)
    }

    /// A control driven by a derived binding renders and edits the field.
    @Test func aControlCanBeHandedADerivedBinding() {
        var storage = Settings(isMuted: true)
        let settings = Binding(get: { storage }, set: { storage = $0 })
        let graph = AttributeGraph()
        var buffer = CellBuffer(width: 20, height: 1)
        let rect = Rect(x: 0, y: 0, width: 20, height: 1)
        GraphContext.$currentEnvironment.withValue(EnvironmentValues()) {
            graph.update(from: Toggle("Muted", isOn: settings.isMuted))
            Layout.measureAndPlace(graph: graph.root!, in: rect)
            GraphRenderer.render(graph.root!, into: &buffer, context: RenderContext(rect: rect))
        }
        let text = String((0..<buffer.width).map { buffer[$0, 0].character })
        #expect(text.hasPrefix("[x] Muted"))
    }
}
