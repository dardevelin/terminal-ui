import Testing
import Foundation
@testable import TerminalUI

// PromptInput markers polish:
//   * Marker text spans render with dim color (not default text color).
//   * `PromptInputLocalizer` protocol routes marker + hint strings.
//   * `.pasteHint(.hidden)` opts out of the auto-hint row.
//   * `PasteBufferContent.image` data shape exists; markerLabel calls
//     `imageMarker(id:)`.

private struct GermanLocalizer: PromptInputLocalizer {
    func textMarker(id: Int, lineCount: Int) -> String {
        "[Eingefügt #\(id) +\(lineCount) Zeilen]"
    }
    func charsMarker(id: Int, charCount: Int) -> String {
        "[Eingefügt #\(id) +\(charCount) Zeichen]"
    }
    func imageMarker(id: Int) -> String {
        "[Bild #\(id)]"
    }
    func pasteAgainHint() -> String {
        "erneut einfügen zum Erweitern"
    }
}

@Suite("PromptInput — marker polish")
@MainActor
struct PromptInputMarkerPolishTests {

    // MARK: - Localizer

    @Test("Default localizer reproduces the existing English marker formats")
    func defaultLocalizerEnglish() {
        let loc = DefaultPromptInputLocalizer()
        #expect(loc.textMarker(id: 1, lineCount: 4) == "[Pasted text #1 +4 lines]")
        #expect(loc.charsMarker(id: 2, charCount: 250) == "[Pasted text #2 +250 chars]")
        #expect(loc.imageMarker(id: 3) == "[Image #3]")
        #expect(loc.pasteAgainHint() == "paste again to expand")
    }

    @Test("Custom localizer wins through markerLabel routing")
    func customLocalizerRoutes() {
        let buffer = PasteBuffer(id: 7, content: .text("a\nb\nc"))
        let ref = PasteReference(id: 7, bufferID: 7, start: 0, length: 5)
        let label = PromptInput.markerLabel(
            for: ref,
            buffers: [buffer],
            localizer: GermanLocalizer()
        )
        #expect(label == "[Eingefügt #7 +3 Zeilen]")
    }

    // MARK: - Image data shape

    @Test("Image content type produces image marker")
    func imageContentMarker() {
        let imageBuffer = PasteBuffer(
            id: 4,
            content: .image(bytes: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png")
        )
        let ref = PasteReference(id: 4, bufferID: 4, start: 0, length: 0)
        let label = PromptInput.markerLabel(
            for: ref,
            buffers: [imageBuffer]
        )
        #expect(label == "[Image #4]")
    }

    @Test("Image buffers are forward-compatible — different bytes hash differently")
    func imageBuffersHashDistinct() {
        let buf1 = PasteBuffer(id: 1, content: .image(bytes: Data([0x01]), mimeType: "image/png"))
        let buf2 = PasteBuffer(id: 2, content: .image(bytes: Data([0x02]), mimeType: "image/png"))
        #expect(buf1.contentHash != buf2.contentHash,
                "different image bytes must produce different content hashes")
    }

    // MARK: - Cursor-adjacent-to-collapsed check

    @Test("Cursor at right edge of collapsed reference triggers hint condition")
    func cursorAtRightEdgeHint() {
        var st = PromptInputState()
        st.references = [PasteReference(id: 1, bufferID: 1, start: 0, length: 5, isExpanded: false)]
        st.buffers = [PasteBuffer(id: 1, content: .text("hello"))]
        st.cursorRow = 0
        st.cursorCol = 5
        #expect(PromptInput.isCursorAtCollapsedRightEdge(state: st, expandedText: "hello"))
    }

    @Test("Cursor mid-buffer of collapsed reference does NOT trigger hint")
    func cursorMidCollapsedNoHint() {
        var st = PromptInputState()
        st.references = [PasteReference(id: 1, bufferID: 1, start: 0, length: 5, isExpanded: false)]
        st.buffers = [PasteBuffer(id: 1, content: .text("hello"))]
        st.cursorRow = 0
        st.cursorCol = 3
        #expect(!PromptInput.isCursorAtCollapsedRightEdge(state: st, expandedText: "hello"))
    }

    @Test("Expanded reference does NOT trigger hint even at right edge")
    func expandedReferenceNoHint() {
        var st = PromptInputState()
        st.references = [PasteReference(id: 1, bufferID: 1, start: 0, length: 5, isExpanded: true)]
        st.buffers = [PasteBuffer(id: 1, content: .text("hello"))]
        st.cursorRow = 0
        st.cursorCol = 5
        #expect(!PromptInput.isCursorAtCollapsedRightEdge(state: st, expandedText: "hello"))
    }

    @Test("No references at all — hint never triggers")
    func noReferencesNoHint() {
        var st = PromptInputState()
        st.cursorRow = 0
        st.cursorCol = 5
        #expect(!PromptInput.isCursorAtCollapsedRightEdge(state: st, expandedText: "hello"))
    }

    // MARK: - Projection respects custom localizer

    @Test("projectCollapsedDisplay routes through supplied localizer")
    func projectionUsesLocalizer() {
        let buffer = PasteBuffer(id: 1, content: .text("a\nb"))
        let ref = PasteReference(id: 1, bufferID: 1, start: 0, length: 3, isExpanded: false)
        let projection = PromptInput.projectCollapsedDisplay(
            expandedText: "a\nb",
            references: [ref],
            buffers: [buffer],
            localizer: GermanLocalizer()
        )
        #expect(projection.displayText.contains("[Eingefügt #1 +2 Zeilen]"))
    }
}
