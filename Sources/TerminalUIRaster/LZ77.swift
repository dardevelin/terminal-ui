/// One deflate symbol before entropy coding: a literal byte, or a match of
/// `length` bytes `distance` back (RFC 1951 §3.2.5).
struct LZ77Token: Equatable, Sendable {
    /// The literal, or the match length 3–258.
    var value: UInt16
    /// 0 for a literal, else 1–32 768.
    var distance: UInt16

    var isLiteral: Bool { distance == 0 }

    static func literal(_ byte: UInt8) -> LZ77Token { LZ77Token(value: UInt16(byte), distance: 0) }
}

/// The match finder, after RFC 1951 §4: three-byte prefixes hashed into
/// chains of earlier positions, searched newest first, and each match held
/// back a step in case the next position starts a longer one ("lazy
/// matching"). Every limit is fixed, so the same input always yields the
/// same tokens.
enum LZ77 {
    private static let hashBits = 15
    private static let hashMask = (1 << hashBits) - 1
    /// Each byte's contribution is shifted so three of them span the hash.
    private static let hashShift = 5
    /// How many earlier positions one search visits at most: zlib's
    /// `max_chain` at its default level 6.
    private static let maximumChainLength = 128
    private static let noPosition: Int32 = -1

    static func tokens(of input: [UInt8]) -> [LZ77Token] {
        var tokens: [LZ77Token] = []
        tokens.reserveCapacity(input.count / 2)
        var head = [Int32](repeating: noPosition, count: 1 << hashBits)
        var chain = [Int32](repeating: noPosition, count: DeflateFormat.windowSize)
        input.withUnsafeBufferPointer { bytes in
            head.withUnsafeMutableBufferPointer { head in
                chain.withUnsafeMutableBufferPointer { chain in
                    let finder = MatchFinder(bytes: bytes, head: head, chain: chain)
                    finder.run(into: &tokens)
                }
            }
        }
        return tokens
    }

    private struct Match {
        var length = 0
        var distance = 0
        var isUsable: Bool { length >= DeflateFormat.minimumMatchLength }
    }

    private struct MatchFinder {
        let bytes: UnsafeBufferPointer<UInt8>
        let head: UnsafeMutableBufferPointer<Int32>
        let chain: UnsafeMutableBufferPointer<Int32>

        func run(into tokens: inout [LZ77Token]) {
            var position = 0
            var current = search(at: position)
            while position < bytes.count {
                guard current.isUsable else {
                    tokens.append(.literal(bytes[position]))
                    position += 1
                    current = search(at: position)
                    continue
                }
                if current.length < DeflateFormat.maximumMatchLength, position + 1 < bytes.count {
                    let next = search(at: position + 1)
                    if next.length > current.length {
                        tokens.append(.literal(bytes[position]))
                        position += 1
                        current = next
                        continue
                    }
                    insertAll(from: position + 2, to: position + current.length)
                } else {
                    insertAll(from: position + 1, to: position + current.length)
                }
                tokens.append(LZ77Token(value: UInt16(current.length), distance: UInt16(current.distance)))
                position += current.length
                current = search(at: position)
            }
        }

        /// The longest match for the bytes at `position`, newest first so a
        /// tie goes to the nearest; then `position` joins its chain.
        func search(at position: Int) -> Match {
            guard position + DeflateFormat.minimumMatchLength <= bytes.count else { return Match() }
            let hash = hash(at: position)
            let longest = min(DeflateFormat.maximumMatchLength, bytes.count - position)
            var best = Match()
            var candidate = Int(head[hash])
            var visited = 0
            while candidate != Int(noPosition), position - candidate <= DeflateFormat.windowSize,
                  visited < maximumChainLength {
                // A candidate that cannot beat the best differs at the
                // best's last byte; checking it first skips most of them.
                if bytes[candidate + best.length] == bytes[position + best.length] || best.length == 0 {
                    var length = 0
                    while length < longest, bytes[candidate + length] == bytes[position + length] { length += 1 }
                    if length > best.length {
                        best = Match(length: length, distance: position - candidate)
                        if length == longest { break }
                    }
                }
                candidate = Int(chain[candidate & (DeflateFormat.windowSize - 1)])
                visited += 1
            }
            insert(position, hash: hash)
            return best
        }

        /// Positions inside an emitted match join their chains unsearched.
        func insertAll(from start: Int, to end: Int) {
            var position = start
            while position < end, position + DeflateFormat.minimumMatchLength <= bytes.count {
                insert(position, hash: hash(at: position))
                position += 1
            }
        }

        private func insert(_ position: Int, hash: Int) {
            chain[position & (DeflateFormat.windowSize - 1)] = head[hash]
            head[hash] = Int32(position)
        }

        private func hash(at position: Int) -> Int {
            ((Int(bytes[position]) << (2 * hashShift)) ^ (Int(bytes[position + 1]) << hashShift)
                ^ Int(bytes[position + 2])) & hashMask
        }
    }
}
