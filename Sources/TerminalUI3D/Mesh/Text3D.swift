import Foundation
import TerminalUI

/// Lettering as a solid: each dot of the ``DotFont`` 5 × 7 font a block,
/// extruded `depth` deep — a wordmark to turn, or a place name standing
/// over a map.
///
/// The letters' faces, front and back, are drawn in material
/// ``faceMaterial`` and their sides in ``sideMaterial``, so a model gives the
/// faces one colour and the sides a darker one and the letters read at any
/// angle. A dot is one unit square; the text is centred on the origin,
/// reading along +x with its faces toward +z.
///
/// ```swift
/// let title = Text3D("TERMINALUI", depth: 2)
/// scene.add(title.mesh, materials: [Material(theme.accent), Material(theme.primary)])
/// ```
public struct Text3D: Sendable, Equatable {
    /// The material index of the letters' faces.
    public static let faceMaterial = 0
    /// The material index of the letters' sides.
    public static let sideMaterial = 1

    /// The lettering. Letters are drawn in capitals, as the font has them.
    public let string: String
    /// How deep the letters are, in dots.
    public let depth: Double
    /// The blank columns between two letters, in dots.
    public let letterSpacing: Int
    /// The solid.
    public let mesh: Mesh
    /// How wide the lettering is, in dots.
    public let width: Double
    /// How tall the lettering is, in dots: the font's height, times the
    /// lines, with the space between them.
    public let height: Double

    /// `string` as blocks `depth` dots deep, `letterSpacing` blank columns
    /// between letters. A newline starts another line, `lineSpacing` blank
    /// rows below the last, each line centred on the widest.
    public init(_ string: String, depth: Double = 2, letterSpacing: Int = 1, lineSpacing: Int = 2) {
        self.string = string
        self.depth = depth
        self.letterSpacing = max(0, letterSpacing)
        let glyphRows = DotFont.glyphHeight
        let gap = max(0, lineSpacing)
        let lines = string.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            Self.columns(of: line, rows: glyphRows, letterSpacing: max(0, letterSpacing))
        }
        let widest = lines.map(\.count).max() ?? 0
        let rows = lines.count * glyphRows + max(0, lines.count - 1) * gap
        var grid = Array(repeating: Array(repeating: false, count: rows), count: widest)
        for (lineIndex, line) in lines.enumerated() {
            let top = lineIndex * (glyphRows + gap)
            let left = (widest - line.count) / 2
            for (column, dots) in line.enumerated() {
                for (row, lit) in dots.enumerated() where lit { grid[left + column][top + row] = true }
            }
        }
        width = Double(widest)
        height = Double(rows)
        mesh = Self.voxels(columns: grid, rows: rows, depth: depth)
    }

    /// One line's dots, column by column.
    private static func columns(of line: Substring, rows: Int, letterSpacing: Int) -> [[Bool]] {
        var columns: [[Bool]] = []
        for (index, character) in line.enumerated() {
            if index > 0 {
                for _ in 0..<letterSpacing { columns.append(Array(repeating: false, count: rows)) }
            }
            let glyph = DotFont.glyph(for: character).map { Array($0) }
            let glyphWidth = glyph.first?.count ?? 0
            for column in 0..<glyphWidth {
                columns.append((0..<rows).map { row in
                    row < glyph.count && column < glyph[row].count && glyph[row][column] == dotOn
                })
            }
        }
        return columns
    }

    /// The pattern character the font marks a lit dot with.
    private static let dotOn: Character = "#"

    private static func voxels(columns: [[Bool]], rows: Int, depth: Double) -> Mesh {
        let width = columns.count
        func lit(_ column: Int, _ row: Int) -> Bool {
            column >= 0 && column < width && row >= 0 && row < rows && columns[column][row]
        }
        let left = -Double(width) / 2, top = Double(rows) / 2
        let front = depth / 2, back = -depth / 2
        var builder = MeshBuilder()
        for row in 0..<rows {
            let upper = top - Double(row), lower = upper - 1
            // Faces run along a row as one quad: neighbouring dots share a
            // plane and a normal, and a seam would only add triangles.
            var column = 0
            while column < width {
                guard lit(column, row) else {
                    column += 1
                    continue
                }
                var end = column
                while lit(end + 1, row) { end += 1 }
                let from = left + Double(column), to = left + Double(end + 1)
                builder.addQuad([Vector3(from, lower, front), Vector3(to, lower, front),
                                 Vector3(to, upper, front), Vector3(from, upper, front)],
                                facing: .unitZ, material: faceMaterial)
                builder.addQuad([Vector3(from, lower, back), Vector3(to, lower, back),
                                 Vector3(to, upper, back), Vector3(from, upper, back)],
                                facing: -.unitZ, material: faceMaterial)
                column = end + 1
            }
            for column in 0..<width where lit(column, row) {
                let from = left + Double(column), to = from + 1
                if !lit(column, row - 1) {
                    builder.addQuad([Vector3(from, upper, back), Vector3(to, upper, back),
                                     Vector3(to, upper, front), Vector3(from, upper, front)],
                                    facing: .unitY, material: sideMaterial)
                }
                if !lit(column, row + 1) {
                    builder.addQuad([Vector3(from, lower, back), Vector3(to, lower, back),
                                     Vector3(to, lower, front), Vector3(from, lower, front)],
                                    facing: -.unitY, material: sideMaterial)
                }
                if !lit(column - 1, row) {
                    builder.addQuad([Vector3(from, lower, back), Vector3(from, upper, back),
                                     Vector3(from, upper, front), Vector3(from, lower, front)],
                                    facing: -.unitX, material: sideMaterial)
                }
                if !lit(column + 1, row) {
                    builder.addQuad([Vector3(to, lower, back), Vector3(to, upper, back),
                                     Vector3(to, upper, front), Vector3(to, lower, front)],
                                    facing: .unitX, material: sideMaterial)
                }
            }
        }
        return builder.mesh
    }
}
