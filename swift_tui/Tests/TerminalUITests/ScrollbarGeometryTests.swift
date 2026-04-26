import Testing
@testable import TerminalUI

// Scrollbar thumb geometry — pure function so the math is testable
// without firing the renderer.
//
//   scrollbarThumb(viewport: viewportLength,
//                  content:  totalContentLength,
//                  offset:   currentScrollOffset) -> (start: Int, length: Int)?
//
// Returns nil when `content <= viewport` (no scrollbar needed).
// Otherwise the thumb spans `length` cells starting at `start` within
// the `viewport`-cell track. Length is proportional to viewport/content
// (clamped to >= 1 cell). Position is proportional to offset/maxOffset
// where maxOffset = content - viewport.

@Suite("Scrollbar thumb geometry — pure function")
@MainActor
struct ScrollbarGeometryTests {

    @Test("content fits in viewport returns nil — no scrollbar shown")
    func fitsReturnsNil() {
        // 10 cells of viewport, 5 cells of content — fits.
        let result = scrollbarThumb(viewport: 10, content: 5, offset: 0)
        #expect(result == nil)
    }

    @Test("content exactly fills viewport returns nil — no scrollbar shown")
    func exactFitReturnsNil() {
        let result = scrollbarThumb(viewport: 10, content: 10, offset: 0)
        #expect(result == nil)
    }

    @Test("offset 0 places thumb at the top of the track")
    func offsetZeroAtTop() {
        // 20 cells viewport, 100 cells content. Thumb length = 20*20/100 = 4.
        // Offset 0 → thumb starts at row 0.
        let result = scrollbarThumb(viewport: 20, content: 100, offset: 0)
        #expect(result != nil)
        if let r = result {
            #expect(r.start == 0,
                    "offset=0 must place thumb at start of track; got start=\(r.start)")
            #expect(r.length == 4,
                    "20-cell viewport over 100-cell content should yield 4-cell thumb; got length=\(r.length)")
        }
    }

    @Test("max offset places thumb at the bottom of the track")
    func maxOffsetAtBottom() {
        // viewport=20, content=100, maxOffset = 100-20 = 80.
        // Thumb length = 4; thumb at start=16, end=19 (last cell).
        let result = scrollbarThumb(viewport: 20, content: 100, offset: 80)
        #expect(result != nil)
        if let r = result {
            #expect(r.start + r.length == 20,
                    "max-offset thumb must end at viewport's last cell; got start=\(r.start) length=\(r.length)")
        }
    }

    @Test("mid offset places thumb proportionally")
    func midOffsetProportional() {
        // viewport=20, content=100, offset=40 (halfway through the
        // 80-cell maxOffset). Thumb length=4. Thumb start should be
        // roughly 8 (proportional to 40/80 of the available 16-cell
        // travel = (20-4) * 0.5 = 8).
        let result = scrollbarThumb(viewport: 20, content: 100, offset: 40)
        #expect(result != nil)
        if let r = result {
            #expect(r.start == 8,
                    "mid-offset thumb should be at start=8 for offset=40 of maxOffset=80; got start=\(r.start)")
            #expect(r.length == 4)
        }
    }

    @Test("very long content yields minimum 1-cell thumb")
    func clampedMinimumThumb() {
        // viewport=10, content=10000. Mathematically thumb=0.01 cells.
        // We clamp to 1 so the user can still see something.
        let result = scrollbarThumb(viewport: 10, content: 10000, offset: 0)
        #expect(result != nil)
        if let r = result {
            #expect(r.length >= 1,
                    "thumb must clamp to >= 1 cell even for very long content; got length=\(r.length)")
        }
    }

    @Test("thumb never extends past viewport bounds")
    func thumbWithinViewport() {
        // Stress: many offsets across a content/viewport ratio.
        for offset in stride(from: 0, through: 80, by: 7) {
            let result = scrollbarThumb(viewport: 20, content: 100, offset: offset)
            if let r = result {
                #expect(r.start >= 0, "thumb start out of bounds at offset=\(offset)")
                #expect(r.start + r.length <= 20,
                        "thumb extends past viewport at offset=\(offset); start=\(r.start) length=\(r.length)")
            }
        }
    }

    @Test("offset clamps to maxOffset — over-scroll doesn't crash or extend past end")
    func overscrollClamps() {
        // offset > maxOffset shouldn't violate the bounds invariant.
        let result = scrollbarThumb(viewport: 20, content: 100, offset: 999)
        #expect(result != nil)
        if let r = result {
            #expect(r.start + r.length == 20,
                    "over-scroll must clamp thumb to viewport end; got start=\(r.start) length=\(r.length)")
        }
    }
}
