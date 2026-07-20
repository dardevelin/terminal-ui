import Testing
@testable import TerminalUI

// `.frame(min: max:)` exists; `Spacer` is the flex-grow analog. The
// gap is a SwiftUI-style `maxWidth: .infinity` declaration that lets
// a child opt into "fill available space" without a sibling Spacer.
//
// Disabled until `FrameDimension.infinity` (or equivalent) is added.
// The disabled-reason string IS the contract.

@Suite("Frame dimensions support fill-available declaration")
@MainActor
struct FrameInfinityTests {

    @Test(
        "FrameDimension.infinity is a public sentinel for fill-available",
        .disabled(if: true, "FrameDimension.infinity / .frame(maxWidth: .infinity) not implemented yet — pin will go active when the sentinel ships")
    )
    func fillAvailableSentinelExists() {
        // Compile-only red.
        // let _ = Text("probe").frame(maxWidth: .infinity)
    }
}
