/// GIF's variable-length-code LZW (GIF89a, Appendix F).
package enum LZW {
    /// Appendix F: codes are at most 12 bits, so a table of 4096 entries.
    static let maximumCodeWidth = 12
    static let tableCapacity = 1 << maximumCodeWidth
    /// §22: the minimum code size is 2 to 8 — even a two-colour image
    /// starts at 2, because codes 2^n and 2^n + 1 are clear and end.
    static let codeSizes = 2...8

    /// The packed codes for `indices`, every one below
    /// 2^`minimumCodeSize`: a clear code first, end-of-information last.
    ///
    /// A code is as wide as the decoder's table needs when it reads it.
    /// The decoder adds an entry for each code after the first since a
    /// clear, so it runs one entry behind the encoder; the width grows when
    /// the encoder's next code would pass the current width, which is when
    /// the decoder's next code reaches it. When the encoder's table holds
    /// all 4096 entries, a clear code follows at once (at 12 bits) and both
    /// tables start again.
    package static func encode(_ indices: [UInt8], minimumCodeSize: Int) -> [UInt8] {
        precondition(codeSizes.contains(minimumCodeSize), "minimum code size \(minimumCodeSize)")
        let alphabetSize = 1 << minimumCodeSize
        precondition(indices.allSatisfy { Int($0) < alphabetSize }, "an index past 2^\(minimumCodeSize)")
        let clearCode = alphabetSize
        let endCode = clearCode + 1
        let firstFreeCode = clearCode + 2

        // children[prefix · alphabetSize + index] is the code for the
        // prefix's string followed by index, 0 for none: no string's code
        // is 0, which is a root.
        var children = [UInt16](repeating: 0, count: tableCapacity * alphabetSize)
        var writer = BitWriter()
        var width = minimumCodeSize + 1
        var nextCode = firstFreeCode

        func advance() {
            nextCode += 1
            if nextCode > 1 << width, width < maximumCodeWidth { width += 1 }
        }

        writer.write(UInt32(clearCode), bits: width)
        guard var prefix = indices.first.map(Int.init) else {
            writer.write(UInt32(endCode), bits: width)
            return writer.finish()
        }
        for index in indices.dropFirst() {
            let slot = prefix * alphabetSize + Int(index)
            if children[slot] != 0 {
                prefix = Int(children[slot])
                continue
            }
            writer.write(UInt32(prefix), bits: width)
            children[slot] = UInt16(nextCode)
            advance()
            if nextCode == tableCapacity {
                writer.write(UInt32(clearCode), bits: width)
                children = [UInt16](repeating: 0, count: children.count)
                width = minimumCodeSize + 1
                nextCode = firstFreeCode
            }
            prefix = Int(index)
        }
        writer.write(UInt32(prefix), bits: width)
        // On reading that last code the decoder's next free code reaches
        // the encoder's, so end-of-information is as wide as one more
        // entry would make the encoder's codes.
        advance()
        writer.write(UInt32(endCode), bits: width)
        return writer.finish()
    }
}
