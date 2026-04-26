import Testing
@testable import TerminalUI

// Edge indicators (▲▼◀▶) already ship. The proportional thumb-track
// scrollbar (visible track + thumb that moves with scroll position,
// click-to-jump) is what's left.
//
// Disabled until `ScrollIndicatorVisibility.scrollbar` (or a new
// `.scrollbarStyle(_:)` modifier) lands. The disabled-reason string
// IS the contract.

@Suite("ScrollView thumb-track scrollbar")
@MainActor
struct ScrollbarThumbTests {

    @Test(
        "ScrollIndicatorVisibility.scrollbar enables proportional thumb",
        .disabled(if: true, "ScrollIndicatorVisibility.scrollbar / proportional thumb not implemented yet — pin will go active when the case ships")
    )
    func scrollbarVisibilityCaseExists() {
        // Compile-only red. Real test: scroll, assert thumb position
        // moves proportionally in the rendered output.
        // let _: ScrollIndicatorVisibility = .scrollbar
    }
}
