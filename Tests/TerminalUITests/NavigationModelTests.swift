import Foundation
import Testing
@testable import TerminalUI

// NavigationStack resolves each element of its path to a screen through
// `.navigationDestination(for:)`, keyed by the element's *type* — the SwiftUI
// spelling. The registry is recovered from the root's content with the same
// `ViewTree` walk that finds picker options and form labels, so a destination
// declared behind a `ForEach` or an `if` is still found.
//
// These tests pin the model layer: the path, the type-keyed registry, and the
// lookup. Push/pop behaviour and focus are covered in NavigationStackTests.

private struct Item: Hashable { let id: Int }
private struct Category: Hashable { let name: String }

// The registry accumulates through the `_AnyEnvironmentModifier` merge, so
// these tests apply the modifiers to a mutable `EnvironmentValues` the way the
// render pass does, then read the resulting registry.
@MainActor
private func registry(
    _ apply: (inout EnvironmentValues) -> Void
) -> NavigationDestinations {
    var env = EnvironmentValues()
    apply(&env)
    return env.navigationDestinations
}

private func addDestination<D: Hashable, V: TerminalView>(
    _ type: D.Type, _ build: @escaping (D) -> V, to env: inout EnvironmentValues
) {
    NavigationDestinationModifier(build: build).apply(to: &env)
}

@Suite("Navigation — destination registry")
@MainActor
struct NavigationRegistryTests {

    @Test("a destination is recovered and keyed by its value type")
    func destinationKeyedByType() {
        let reg = registry { env in
            addDestination(Item.self, { item in Text("item \(item.id)") }, to: &env)
        }
        #expect(reg.hasDestination(for: Item.self))
        #expect(!reg.hasDestination(for: Category.self))
    }

    @Test("the recovered builder renders the pushed value")
    func builderRendersValue() {
        let reg = registry { env in
            addDestination(Item.self, { item in Text("detail \(item.id)") }, to: &env)
        }
        let screen = reg.screen(for: Item(id: 7))
        #expect(screen != nil)
        #expect(ViewTree.firstText(in: screen as Any) == "detail 7")
    }

    @Test("destinations for several types coexist")
    func multipleTypesCoexist() {
        let reg = registry { env in
            addDestination(Item.self, { item in Text("item \(item.id)") }, to: &env)
            addDestination(Category.self, { cat in Text("cat \(cat.name)") }, to: &env)
        }
        #expect(reg.hasDestination(for: Item.self))
        #expect(reg.hasDestination(for: Category.self))
        #expect(ViewTree.firstText(in: reg.screen(for: Category(name: "A")) as Any) == "cat A")
    }

    // Pushing a value whose type has no destination is a consumer bug: it must
    // be reported, not silently render blank.
    @Test("a value with no registered destination yields nil")
    func unregisteredValueYieldsNil() {
        let reg = NavigationDestinations()
        #expect(reg.screen(for: Item(id: 1)) == nil)
    }

    // Registrations accumulate rather than the last one replacing the rest.
    @Test("a second registration does not clobber the first")
    func registrationsAccumulate() {
        let reg = registry { env in
            addDestination(Item.self, { item in Text("item \(item.id)") }, to: &env)
            addDestination(Category.self, { cat in Text("cat \(cat.name)") }, to: &env)
        }
        #expect(reg.hasDestination(for: Item.self))
        #expect(reg.hasDestination(for: Category.self))
    }
}

@Suite("Navigation — path")
@MainActor
struct NavigationPathTests {

    @Test("an unbound stack starts empty and manages its own path")
    func unboundStackStartsEmpty() {
        let path = NavigationPathStore()
        #expect(path.isEmpty)
        path.append(Item(id: 1))
        #expect(path.count == 1)
    }

    @Test("removeLast pops one, on an empty path it is a no-op")
    func removeLastPopsAndIsSafe() {
        let path = NavigationPathStore()
        path.append(Item(id: 1))
        path.append(Item(id: 2))
        path.removeLast()
        #expect(path.count == 1)
        path.removeLast()
        #expect(path.isEmpty)
        path.removeLast()  // must not crash
        #expect(path.isEmpty)
    }

    @Test("the top element drives which screen shows")
    func topElementIsCurrent() {
        let path = NavigationPathStore()
        path.append(Item(id: 1))
        path.append(Category(name: "B"))
        #expect(path.top as? Category == Category(name: "B"))
    }
}
