/// Length-limited prefix codes for deflate's dynamic blocks.
enum HuffmanCode {

    /// The optimal code lengths for `frequencies` with none longer than
    /// `limit`, by package-merge (Larmore and Hirschberg, "A fast algorithm
    /// for optimal length-limited Huffman codes", JACM 37(3), 1990). A
    /// symbol of frequency 0 gets length 0, no code.
    ///
    /// Fewer than two used symbols would make a one-code or empty code,
    /// which zlib's inflate rejects for literals (RFC 1951 §3.2.7 permits
    /// the one-code case only for distances); like zlib's deflate, the
    /// lowest unused symbols are given a code too, until there are two.
    static func lengths(frequencies: [Int], limit: Int) -> [Int] {
        precondition(frequencies.count >= 2, "a code of \(frequencies.count) symbols")
        var weights = frequencies
        var unused = weights.indices.filter { weights[$0] == 0 }[...]
        while weights.count - unused.count < 2, let symbol = unused.popFirst() {
            weights[symbol] = 1
        }
        let leaves = weights.indices.filter { weights[$0] > 0 }
            .sorted { (weights[$0], $0) < (weights[$1], $1) }
        precondition(leaves.count <= 1 << limit, "\(leaves.count) symbols cannot fit \(limit) bits")

        // Each list is the coins of one denomination, cheapest first: the
        // leaves, merged with the previous list's items paired into
        // packages. Only whether an item is a package needs keeping: the
        // first k items of a list hold its cheapest leaves, and the first p
        // packages are the first 2p items of the list below.
        let leafWeights = leaves.map { weights[$0] }
        var levels: [[Bool]] = [[Bool](repeating: false, count: leaves.count)]
        var previous = leafWeights
        for _ in 1..<limit {
            let packages = stride(from: 0, to: previous.count - 1, by: 2).map { previous[$0] + previous[$0 + 1] }
            var merged: [Int] = []
            var isPackage: [Bool] = []
            var leaf = 0
            var package = 0
            while leaf < leafWeights.count || package < packages.count {
                // A leaf goes first on a tie: any order is optimal, this
                // one is fixed.
                if package == packages.count
                    || (leaf < leafWeights.count && leafWeights[leaf] <= packages[package]) {
                    merged.append(leafWeights[leaf])
                    isPackage.append(false)
                    leaf += 1
                } else {
                    merged.append(packages[package])
                    isPackage.append(true)
                    package += 1
                }
            }
            levels.append(isPackage)
            previous = merged
        }

        // The cheapest 2n − 2 items of the last list form the code; each
        // time a leaf is among the items taken, its code grows one bit.
        var leafLengths = [Int](repeating: 0, count: leaves.count)
        var taken = 2 * leaves.count - 2
        for isPackage in levels.reversed() {
            let packages = isPackage[..<taken].count { $0 }
            for leaf in 0..<(taken - packages) { leafLengths[leaf] += 1 }
            taken = 2 * packages
        }

        var lengths = [Int](repeating: 0, count: frequencies.count)
        for (rank, symbol) in leaves.enumerated() { lengths[symbol] = leafLengths[rank] }
        return lengths
    }

    /// The canonical code for each length, most significant bit first
    /// (RFC 1951 §3.2.2): shorter codes sort before longer, and codes of
    /// one length follow their symbols' order.
    static func canonicalCodes(lengths: [Int]) -> [UInt32] {
        let longest = lengths.max() ?? 0
        var lengthCounts = [UInt32](repeating: 0, count: longest + 1)
        for length in lengths where length > 0 { lengthCounts[length] += 1 }
        var nextCode = [UInt32](repeating: 0, count: longest + 1)
        var code: UInt32 = 0
        for length in stride(from: 1, through: longest, by: 1) {
            code = (code + lengthCounts[length - 1]) << 1
            nextCode[length] = code
        }
        return lengths.map { length in
            guard length > 0 else { return 0 }
            defer { nextCode[length] += 1 }
            return nextCode[length]
        }
    }

    /// `code`'s low `length` bits in reverse order: a Huffman code is sent
    /// most significant bit first into a stream packed from the least
    /// (RFC 1951 §3.1.1), so it is written reversed.
    static func reversed(_ code: UInt32, length: Int) -> UInt32 {
        var reversed: UInt32 = 0
        for bit in 0..<length where code & (1 << UInt32(bit)) != 0 {
            reversed |= 1 << UInt32(length - 1 - bit)
        }
        return reversed
    }
}
