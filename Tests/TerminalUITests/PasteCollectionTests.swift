import Testing
@testable import TerminalUI

// InputParser bracketed-paste collection must tolerate
// transient `readByte()` nils (raw-mode timeouts), not terminate
// on the first one. Without this, a paste split across multiple
// stdin reads collapses to a partial payload and the unread bytes
// (including the `ESC[201~` end marker and trailing characters)
// drain into the parser as raw input — corrupting the UI and the
// terminal.

/// Simulates a stdin source that hands out bytes in chunks separated
/// by transient nils — exactly what raw-mode VTIME=1 produces when the
/// terminal pacing splits a paste across multiple `read()` syscalls.
private struct ChunkedByteSource: ByteSource {
    var chunks: [[UInt8]]   // remaining chunks (current + future)
    var pos: Int = 0
    var nilPending: Bool = false   // emit a transient nil before the next chunk

    init(_ chunks: [[UInt8]]) {
        self.chunks = chunks
    }

    mutating func readByte() -> UInt8? {
        if nilPending {
            nilPending = false
            return nil   // transient timeout between chunks
        }
        guard !chunks.isEmpty else { return nil }
        let chunk = chunks[0]
        if pos < chunk.count {
            let byte = chunk[pos]
            pos += 1
            return byte
        }
        // Chunk exhausted — drop it, set nilPending, recurse to deliver
        // either the nil-as-timeout or (if no more chunks) terminal nil.
        chunks.removeFirst()
        pos = 0
        if !chunks.isEmpty {
            nilPending = true
            return nil
        }
        return nil
    }
}

@Suite("InputParser — bracketed-paste collection survives transient nils")
@MainActor
struct PasteCollectionTests {

    @Test("Paste fully contained in a single chunk parses correctly")
    func singleChunk() {
        let payload = Array("hello world".utf8)
        let bytes: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]   // ESC[200~
            + payload
            + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]                  // ESC[201~
        var source = ArrayByteSource(bytes)
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let text) = event else {
            Issue.record("expected .paste event, got \(String(describing: event))")
            return
        }
        #expect(text == "hello world")
    }

    @Test("Paste split across chunks survives transient nil between chunks")
    func splitAcrossChunks() {
        // Simulates a 2KB paste where the OS read returned the start
        // marker + half the payload, paused, then delivered the rest +
        // end marker on a subsequent read.
        let half1 = Array("first-half-of-paste-".utf8)
        let half2 = Array("second-half-of-paste".utf8)
        let chunk1: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + half1
        let chunk2: [UInt8] = half2 + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        var source = ChunkedByteSource([chunk1, chunk2])
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let text) = event else {
            Issue.record("expected .paste event, got \(String(describing: event))")
            return
        }
        #expect(text == "first-half-of-paste-second-half-of-paste",
                "split paste must concatenate, not truncate at chunk boundary")
    }

    @Test("Large paste split across many chunks completes intact")
    func manyChunks() {
        let blob = String(repeating: "abcdefghij\n", count: 200)   // 2200 chars
        let payload = Array(blob.utf8)
        // Chop payload into 10 chunks of ~220 bytes each.
        var chunks: [[UInt8]] = []
        let startMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
        let endMarker: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        let chunkSize = payload.count / 10
        chunks.append(startMarker + Array(payload.prefix(chunkSize)))
        for i in 1..<9 {
            let start = i * chunkSize
            let end = (i + 1) * chunkSize
            chunks.append(Array(payload[start..<end]))
        }
        chunks.append(Array(payload[(9 * chunkSize)...]) + endMarker)
        var source = ChunkedByteSource(chunks)
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let text) = event else {
            Issue.record("expected .paste event, got \(String(describing: event))")
            return
        }
        #expect(text == blob,
                "large paste split across 10 chunks must reassemble verbatim")
    }

    @Test("Paste payload containing ESC bytes that aren't end marker is preserved")
    func payloadWithEmbeddedESC() {
        // A paste from a terminal-output recording could contain ESC
        // bytes mid-payload (e.g. preserved ANSI sequences). These
        // must survive unless they form the literal ESC[201~ end.
        let payload: [UInt8] = [0x1B, 0x5B, 0x33, 0x31, 0x6D]   // ESC[31m (red)
            + Array("text".utf8)
            + [0x1B, 0x5B, 0x30, 0x6D]                          // ESC[0m (reset)
        let bytes: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E]
            + payload
            + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]
        var source = ArrayByteSource(bytes)
        let event = InputParser.parseEvent(from: &source)
        guard case .paste(let text) = event else {
            Issue.record("expected .paste, got \(String(describing: event))")
            return
        }
        // The payload's bytes should round-trip — UTF-8 decode preserves
        // ESC (0x1B) inside the resulting string.
        let decoded = Array(text.utf8)
        #expect(decoded == payload,
                "payload bytes including embedded ESC must round-trip")
    }
}
