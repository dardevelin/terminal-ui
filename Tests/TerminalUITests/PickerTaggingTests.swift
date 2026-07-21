import Foundation
import Testing
@testable import TerminalUI

// `.tag(_:)` is a general view modifier, not a Picker-private descriptor.
// That choice is what makes `ForEach` compose: the option list is ordinary
// `@TerminalViewBuilder` content, so every construct the builder already
// understands — tuples, `ForEach`, `if`/`else` — works inside a `Picker`
// without a bespoke builder that would have to re-implement each one.
//
// The tag travels in the *static type* (`TaggedView<Theme, Text>`), so
// recovering it is a typed protocol witness rather than an `AnyHashable`
// downcast. Nothing about selection identity is stored in the render graph:
// identity lives in the `Binding`, and the option list is rebuilt from the
// content value on each body evaluation, which is what keeps a reordered or
// filtered option set correct without an invalidation story.

private enum Theme: String, Hashable, CaseIterable {
    case light, dark, auto
}

private struct Named: Identifiable {
    let id: Int
    let name: String
}

/// A user-written view whose `body` produces the options — the shape a real
/// app reaches for when the option list is worth naming.
private struct ThemeOptions: TerminalView {
    var body: some TerminalView {
        VStack {
            Text("Light").tag(Theme.light)
            Text("Dark").tag(Theme.dark)
        }
    }
}

@Suite("Picker — option collection")
@MainActor
struct PickerTaggingTests {

    @Test("a tagged view exposes its tag and renders as its content")
    func tagIsRecoverable() {
        let tagged = Text("Light").tag(Theme.light)
        #expect(tagged.pickerTag as? Theme == Theme.light)
    }

    @Test("options are collected from builder content in declaration order")
    func collectsInDeclarationOrder() {
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                Text("Light").tag(Theme.light),
                Text("Dark").tag(Theme.dark),
                Text("Auto").tag(Theme.auto)
            ),
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light, .dark, .auto])
        #expect(options.map(\.title) == ["Light", "Dark", "Auto"])
    }

    // The reason `.tag()` is a view modifier rather than a descriptor type.
    // A `@PickerOptionBuilder` accepting only descriptors would reject this,
    // and it is the most common way a real settings screen is written.
    @Test("ForEach content contributes options")
    func forEachContributesOptions() {
        let items = [Named(id: 1, name: "One"), Named(id: 2, name: "Two")]
        let options = PickerOptions.collect(
            from: ForEach(items) { item in
                Text(item.name).tag(item.id)
            },
            as: Int.self
        )
        #expect(options.map(\.value) == [1, 2])
        #expect(options.map(\.title) == ["One", "Two"])
    }

    @Test("conditional content contributes only the taken branch")
    func conditionalContributesTakenBranch() {
        let showAuto = false
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                Text("Light").tag(Theme.light),
                showAuto
                    ? TerminalViewBuilder.buildEither(first: Text("Auto").tag(Theme.auto))
                    : TerminalViewBuilder.buildEither(second: Text("Dark").tag(Theme.dark))
            ),
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light, .dark])
    }

    @Test("untagged content is ignored rather than treated as an option")
    func untaggedContentIgnored() {
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                Text("a heading"),
                Text("Light").tag(Theme.light)
            ),
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light])
    }

    // A tag of the wrong type is a consumer bug that would otherwise present
    // as a silently missing row, so it must not be quietly dropped.
    @Test("a tag of a different type is not collected")
    func mismatchedTagTypeIgnored() {
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                Text("Light").tag(Theme.light),
                Text("Nine").tag(9)
            ),
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light])
    }

    @Test("duplicate tags keep the first and warn")
    func duplicateTagsFirstWins() {
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                Text("Light").tag(Theme.light),
                Text("Light again").tag(Theme.light),
                Text("Dark").tag(Theme.dark)
            ),
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light, .dark])
        #expect(options.map(\.title) == ["Light", "Dark"])
    }

    @Test("no options yields an empty list rather than a crash")
    func emptyContentYieldsNoOptions() {
        let options = PickerOptions.collect(from: EmptyView(), as: Theme.self)
        #expect(options.isEmpty)
    }

    // Traversal must open containers through the same witnesses the graph
    // uses. `extractChildren` unwraps a `TupleView`'s packed tuple but returns
    // a `VStack` unchanged — walking only tuples silently dropped every option
    // nested inside a stack, and the multi-child tests above could not see it.
    @Test("options nested in a stack are collected", arguments: [0, 1, 2])
    func optionsInsideStacksAreCollected(shape: Int) {
        let content: any TerminalView = switch shape {
        case 0: VStack { Text("Light").tag(Theme.light) }
        case 1: HStack { Text("Light").tag(Theme.light) }
        default: ZStack { Text("Light").tag(Theme.light) }
        }
        let options = PickerOptions.collect(from: content, as: Theme.self)
        #expect(options.map(\.value) == [.light])
        #expect(options.map(\.title) == ["Light"])
    }

    @Test("a single-child container of the same type still yields its options")
    func nestedSameTypeContainerCollected() {
        let options = PickerOptions.collect(
            from: VStack { VStack { Text("Dark").tag(Theme.dark) } },
            as: Theme.self
        )
        #expect(options.map(\.value) == [.dark])
    }

    // Traversal must open every container the view builder can produce, not a
    // hand-picked subset. Each case below silently dropped its option while
    // the walker enumerated container protocols by name.
    @Test("a modifier applied after .tag() does not hide the option")
    func modifiedTaggedViewIsCollected() {
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                Text("Light").tag(Theme.light).padding(1),
                Text("Dark").tag(Theme.dark)
            ),
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light, .dark])
    }

    @Test("a styled label still yields its title")
    func styledLabelKeepsTitle() {
        let options = PickerOptions.collect(
            from: Text("Light").foreground(.red).tag(Theme.light),
            as: Theme.self
        )
        #expect(options.map(\.title) == ["Light"])
    }

    @Test("options inside a ScrollView are collected")
    func optionsInsideScrollViewCollected() {
        let options = PickerOptions.collect(
            from: ScrollView { VStack { Text("Light").tag(Theme.light) } },
            as: Theme.self
        )
        #expect(options.map(\.value) == [.light])
    }

    @Test("options produced by a composite view's body are collected")
    func optionsFromCompositeBodyCollected() {
        let options = PickerOptions.collect(from: ThemeOptions(), as: Theme.self)
        #expect(options.map(\.value) == [.light, .dark])
    }

    @Test("a grouped option keeps the label from its nested Text")
    func titleFoundBeneathAContainer() {
        let options = PickerOptions.collect(
            from: TerminalViewBuilder.buildBlock(
                HStack { Text("Light") }.tag(Theme.light)
            ),
            as: Theme.self
        )
        #expect(options.map(\.title) == ["Light"])
    }
}
