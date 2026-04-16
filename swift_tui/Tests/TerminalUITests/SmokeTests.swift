import Testing
@testable import TerminalUI

@Suite("Smoke")
struct SmokeTests {

    @Test("CellBuffer construction")
    func cellBufferConstruction() {
        let buffer = CellBuffer(width: 10, height: 5)
        #expect(buffer.width == 10)
        #expect(buffer.height == 5)
        #expect(buffer.cells.count == 50)
    }
}
