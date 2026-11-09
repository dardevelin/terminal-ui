import Foundation
import Testing
import TerminalUI
@testable import TerminalUIRecording

// The shapes a picture draws in place of a font's glyphs, checked against
// sources that do not share their tables: the Unicode names of the box
// drawing characters, the framework's own sub-cell code for quadrants and
// braille, and the list of glyphs the framework draws.

/// Which pixels a resolved glyph's rectangles cover: the box-drawing lines
/// and block elements are rectangles only.
private struct Coverage {
    let width: Int
    let height: Int
    private var covered: [Bool]

    init(_ glyph: DeviceGlyph) {
        width = glyph.width
        height = glyph.height
        covered = Array(repeating: false, count: glyph.width * glyph.height)
        for mark in glyph.marks {
            guard case .rect(let x, let y, let rectWidth, let rectHeight) = mark.figure else { continue }
            for row in max(y, 0)..<min(y + rectHeight, height) {
                for column in max(x, 0)..<min(x + rectWidth, width) {
                    covered[row * width + column] = true
                }
            }
        }
    }

    subscript(x: Int, y: Int) -> Bool { covered[y * width + x] }

    /// The lengths of the covered runs along a row or a column.
    func runs(_ pixels: [(Int, Int)]) -> [Int] {
        var runs: [Int] = []
        var current = 0
        for (x, y) in pixels {
            if self[x, y] {
                current += 1
            } else if current > 0 {
                runs.append(current)
                current = 0
            }
        }
        return current > 0 ? runs + [current] : runs
    }

    /// Whether the covered pixels are one 4-connected piece.
    var isConnected: Bool {
        guard let first = covered.firstIndex(of: true) else { return true }
        var seen = Set([first])
        var stack = [first]
        while let index = stack.popLast() {
            let (x, y) = (index % width, index / width)
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
            where nx >= 0 && nx < width && ny >= 0 && ny < height && self[nx, ny] {
                if seen.insert(ny * width + nx).inserted { stack.append(ny * width + nx) }
            }
        }
        return seen.count == covered.filter { $0 }.count
    }
}

/// A box-drawing character's arms as its Unicode name states them: `LIGHT`
/// or `HEAVY` or `DOUBLE` (`SINGLE` is light) before the directions it
/// governs ("HEAVY DOWN AND RIGHT") or after them ("DOWN LIGHT AND RIGHT
/// HEAVY"); `HORIZONTAL` is left and right, `VERTICAL` up and down.
private func armsFromName(_ name: String) -> [String: String] {
    let weights = ["LIGHT": "light", "SINGLE": "light", "HEAVY": "heavy", "DOUBLE": "double"]
    let directions = ["UP": ["up"], "DOWN": ["down"], "LEFT": ["left"], "RIGHT": ["right"],
                      "HORIZONTAL": ["left", "right"], "VERTICAL": ["up", "down"]]
    var arms: [String: String] = [:]
    var pending: [String] = []
    var leading: String?
    for word in name.dropFirst("BOX DRAWINGS ".count).split(separator: " ").map(String.init) {
        if let weight = weights[word] {
            if pending.isEmpty {
                leading = weight
            } else {
                for direction in pending { arms[direction] = weight }
                pending = []
                leading = nil
            }
        } else if let named = directions[word] {
            for direction in named {
                if let leading { arms[direction] = leading } else { pending.append(direction) }
            }
        }
    }
    return arms
}

private func scalar(_ value: UInt32) -> Unicode.Scalar { Unicode.Scalar(value)! }

private func resolved(_ value: UInt32, width: Int = 18, height: Int = 36) -> DeviceGlyph? {
    GlyphGeometry.shape(for: scalar(value)).map { DeviceGlyph($0, cellWidth: width, cellHeight: height) }
}

@Suite("Glyph geometry")
struct GlyphGeometryTests {

    @Test func everyCodePointOfTheThreeBlocksIsAShape() {
        for range in [GlyphGeometry.boxDrawing, GlyphGeometry.blockElements, GlyphGeometry.braille] {
            for value in range {
                let shape = GlyphGeometry.shape(for: scalar(value))
                #expect(shape != nil, "U+\(String(value, radix: 16, uppercase: true)) has no shape")
                // Only the blank braille pattern draws nothing.
                #expect(value == 0x2800 || shape?.primitives.isEmpty == false,
                        "U+\(String(value, radix: 16, uppercase: true)) draws nothing")
            }
        }
    }

    @Test func aClusterOrAnotherCharacterIsTheFonts() {
        let characters: [Character] = ["a", "→", "\u{2502}\u{0301}", "\u{2502}"]
        #expect(characters.map { GlyphGeometry.shape(for: $0) != nil } == [false, false, false, true])
    }

    /// At each edge's middle, the lines that reach it are the arms the name
    /// gives: none, one light stroke, one heavy, or two light.
    @Test func boxDrawingArmsAreTheOnesTheirNamesGive() throws {
        let widths = StrokeWidths(cellWidth: 18)
        for value in GlyphGeometry.boxDrawing {
            let name = try #require(scalar(value).properties.name)
            guard !["DASH", "ARC", "DIAGONAL"].contains(where: name.contains) else { continue }
            let coverage = Coverage(try #require(resolved(value)))
            let (width, height) = (coverage.width, coverage.height)
            let edges: [String: [(Int, Int)]] = [
                "up": (0..<width).map { ($0, 0) }, "down": (0..<width).map { ($0, height - 1) },
                "left": (0..<height).map { (0, $0) }, "right": (0..<height).map { (width - 1, $0) },
            ]
            let expected = armsFromName(name)
            for (direction, pixels) in edges {
                let runs = coverage.runs(pixels)
                let found: String? = switch runs {
                case []: nil
                case [widths.light]: "light"
                case [widths.heavy]: "heavy"
                case [widths.light, widths.light]: "double"
                default: "runs \(runs)"
                }
                #expect(found == expected[direction], "\(name): \(direction) is \(found ?? "none")")
            }
        }
    }

    /// Arms of light and heavy lines meet without a notch: every such glyph
    /// is one piece.
    @Test func singleLineArmsJoinAtTheCentre() throws {
        for value in GlyphGeometry.boxDrawing {
            let name = try #require(scalar(value).properties.name)
            guard !["DASH", "ARC", "DIAGONAL", "DOUBLE"].contains(where: name.contains) else { continue }
            for (width, height) in [(9, 18), (18, 36), (10, 21)] {
                let coverage = Coverage(try #require(resolved(value, width: width, height: height)))
                #expect(coverage.isConnected, "\(name) at \(width)×\(height) is in pieces")
            }
        }
    }

    /// A border drawn one cell after another is one line: each rounded
    /// corner's arc ends on the cell's side edge across exactly the rows ─
    /// covers, and on the vertical line across exactly │'s columns, which
    /// its tail carries on to the top or bottom edge.
    @Test func roundedCornersMeetTheLinesBesideThem() throws {
        let perPixel = SubpixelPoint.perPixel
        for (width, height) in [(9, 18), (18, 36), (10, 21)] {
            let horizontal = Coverage(try #require(resolved(0x2500, width: width, height: height)))
            let vertical = Coverage(try #require(resolved(0x2502, width: width, height: height)))
            let rows = (0..<height).filter { horizontal[0, $0] }
            let columns = (0..<width).filter { vertical[$0, 0] }
            for corner: UInt32 in [0x256D, 0x256E, 0x256F, 0x2570] {
                let label = "U+\(String(corner, radix: 16, uppercase: true)) at \(width)×\(height)"
                let glyph = try #require(resolved(corner, width: width, height: height))
                guard case .quarterRing(let centre, let inner, let outer, let quarter) = glyph.marks.first?.figure else {
                    Issue.record("\(label) does not start with its arc")
                    continue
                }
                #expect(centre.x == 0 || centre.x == width * perPixel, "\(label): the arc's centre is on a side edge")
                let rowBand = quarter.vertical < 0 ? [centre.y - outer, centre.y - inner]
                                                   : [centre.y + inner, centre.y + outer]
                #expect(rowBand == [rows[0] * perPixel, (rows[rows.count - 1] + 1) * perPixel], "\(label)")
                let columnBand = quarter.horizontal < 0 ? [centre.x - outer, centre.x - inner]
                                                        : [centre.x + inner, centre.x + outer]
                #expect(columnBand == [columns[0] * perPixel, (columns[columns.count - 1] + 1) * perPixel], "\(label)")
                let tail = Coverage(glyph)
                let edgeRow = quarter.vertical < 0 ? height - 1 : 0
                #expect((0..<width).filter { tail[$0, edgeRow] } == columns, "\(label): the tail reaches the edge")
            }
        }
    }

    /// The framework picks quadrant glyphs from a pattern of lit quarters
    /// (`SubCellRenderer`, `QuadrantMask`); each glyph it picks covers
    /// exactly those quarters.
    @Test func quadrantsCoverTheQuartersTheFrameworkLights() throws {
        let corners: [(QuadrantMask, Int, Int)] = [(.topLeft, 0, 0), (.topRight, 1, 0), (.bottomLeft, 0, 1),
                                                   (.bottomRight, 1, 1)]
        for raw in UInt8(0)...15 {
            let mask = QuadrantMask(rawValue: raw)
            var pattern = AlphaPattern(uniformValue: 0)
            for (quarter, column, row) in corners where mask.contains(quarter) {
                for y in (2 * row)..<(2 * row + 2) { pattern[column, y] = 1 }
            }
            let picked = SubCellRenderer.render(pattern, foreground: .white, background: .black)
            for character in Set([SubCellGlyph.quadrant(mask).character, picked.glyph.character]) {
                guard raw != 0 else {
                    #expect(GlyphGeometry.shape(for: SubCellGlyph.quadrant(mask).character) == nil)
                    continue
                }
                let shape = try #require(GlyphGeometry.shape(for: character), "\(character) has no shape")
                let coverage = Coverage(DeviceGlyph(shape, cellWidth: 8, cellHeight: 16))
                for (quarter, column, row) in corners {
                    #expect(coverage[2 + 4 * column, 4 + 8 * row] == mask.contains(quarter),
                            "\(character): the \(quarter) quarter")
                }
            }
        }
    }

    /// Every set of the eight dot positions, drawn by `BrailleCanvas` as the
    /// framework draws a chart, gives a glyph whose dots sit at exactly
    /// those positions: a column is half the cell, a row a quarter of it.
    @Test func brailleDotsSitWhereBrailleCanvasPutsThem() throws {
        let positions = (0..<4).flatMap { row in (0..<2).map { column in (column, row) } }
        let (width, height) = (8, 16)
        for subset in 0..<256 {
            var canvas = BrailleCanvas(width: 1, height: 1)
            var expected: Set<[Int]> = []
            for (index, position) in positions.enumerated() where subset & (1 << index) != 0 {
                canvas.set(x: position.0, y: position.1)
                expected.insert([position.0, position.1])
            }
            let character = try #require(canvas.render().first)
            let glyph = DeviceGlyph(try #require(GlyphGeometry.shape(for: character)), cellWidth: width, cellHeight: height)
            var found: Set<[Int]> = []
            for mark in glyph.marks {
                guard case .circle(let centre, let radius) = mark.figure else { continue }
                let perPixel = SubpixelPoint.perPixel
                found.insert([centre.x * 2 / (width * perPixel), centre.y * 4 / (height * perPixel)])
                // Inside its own share of the cell, clear of its neighbours.
                #expect(centre.x - radius > (centre.x * 2 / (width * perPixel)) * width * perPixel / 2)
                #expect(centre.y + radius < (centre.y * 4 / (height * perPixel) + 1) * height * perPixel / 4)
            }
            #expect(found == expected, "\(character): dots at \(found.sorted { $0.lexicographicallyPrecedes($1) })")
        }
    }

    @Test func shadesAreAQuarterHalfAndThreeQuartersOpaque() throws {
        for (value, opacity) in [(UInt32(0x2591), Proportion(1, 4)), (0x2592, Proportion(1, 2)), (0x2593, Proportion(3, 4))] {
            let shape = try #require(GlyphGeometry.shape(for: scalar(value)))
            #expect(shape.primitives.map(\.opacity) == [opacity])
            let coverage = Coverage(DeviceGlyph(shape, cellWidth: 9, cellHeight: 18))
            #expect((0..<18).allSatisfy { y in (0..<9).allSatisfy { coverage[$0, y] } })
        }
    }

    @Test func eighthsFillFromTheirEdge() throws {
        for eighths in 1...8 {
            let lower = Coverage(try #require(resolved(0x2580 + UInt32(eighths), width: 8, height: 16)))
            #expect((0..<16).filter { lower[0, $0] } == Array((16 - 2 * eighths)..<16), "lower \(eighths)/8")
        }
        for eighths in 1...7 {
            let left = Coverage(try #require(resolved(0x2590 - UInt32(eighths), width: 8, height: 16)))
            #expect((0..<8).filter { left[$0, 0] } == Array(0..<eighths), "left \(eighths)/8")
        }
    }

    /// The chrome is drawn about the cell's centre and stays inside it.
    @Test func chromeStaysInsideItsCell() throws {
        for value in GlyphGeometry.chrome {
            let glyph = try #require(resolved(value, width: 9, height: 18))
            let perPixel = SubpixelPoint.perPixel
            for mark in glyph.marks {
                switch mark.figure {
                case .rect(let x, let y, let width, let height):
                    #expect(x >= 0 && y >= 0 && x + width <= 9 && y + height <= 18)
                case .polygon(let points):
                    #expect(points.allSatisfy { (0...9 * perPixel).contains($0.x) && (0...18 * perPixel).contains($0.y) })
                case .circle(let centre, let radius):
                    #expect(centre.x - radius >= 0 && centre.x + radius <= 9 * perPixel)
                case .quarterRing:
                    Issue.record("chrome has no rounded corner")
                }
            }
        }
    }

    /// `tools/font-glyphs.txt` says which characters the framework draws are
    /// shapes; each one it calls a shape is one, and each it leaves to the
    /// font is not.
    @Test func theGlyphListAgreesWithTheGeometry() throws {
        let list = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("tools/font-glyphs.txt")
        var checked = 0
        for line in try String(contentsOf: list, encoding: .utf8).split(separator: "\n")
        where !line.hasPrefix("#") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let fields = line.split(separator: " ", maxSplits: 3)
            try #require(fields.count == 4, "\(line)")
            let bounds = fields[0].split(separator: ".", omittingEmptySubsequences: true)
                .map { UInt32($0.dropFirst(2), radix: 16) }
            let first = try #require(bounds.first ?? nil), last = try #require(bounds.last ?? nil)
            for value in first...last {
                let isShape = GlyphGeometry.shape(for: scalar(value)) != nil
                #expect(isShape == (fields[2] == "shape"), "\(line): U+\(String(value, radix: 16, uppercase: true))")
                checked += 1
            }
        }
        #expect(checked > 0)
    }

    @Test func integerHelpersRoundHalfUpForEitherSign() {
        #expect(roundedDivision(7, 2) == 4 && roundedDivision(5, 2) == 3 && roundedDivision(4, 3) == 1)
        #expect(roundedDivision(-7, 2) == -3 && roundedDivision(-8, 3) == -3 && roundedDivision(0, 5) == 0)
        #expect([0, 1, 3, 4, 15, 16, 17, 1_000_000].map(integerSquareRoot) == [0, 1, 1, 2, 3, 4, 4, 1_000])
    }
}
