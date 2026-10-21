// Compositor.compositeAlphaLayer. Walks an AlphaLayer
// cell-by-cell and writes the result into a destination CellBuffer
// at an offset. Pure pass-through when alpha=1.0, no-op when
// alpha=0.0, RGB blending otherwise.
//
// Color blending is meaningful only for `.rgb(...)` cases. Other
// Color cases (named colors, ansi256) are resolved to an
// approximate RGB equivalent first; the blended result is always
// emitted as `.rgb(...)`. Downstream consumers see a single
// canonical form.

extension Compositor {

    /// Composite an AlphaLayer onto an existing CellBuffer at the
    /// given offset. Cells outside the destination buffer's bounds
    /// are silently clipped.
    public static func compositeAlphaLayer(
        _ layer: AlphaLayer,
        at offset: Point,
        into buffer: inout CellBuffer
    ) {
        for ly in 0..<layer.height {
            for lx in 0..<layer.width {
                let dx = offset.x + lx
                let dy = offset.y + ly

                // Clip to destination bounds.
                guard dx >= 0, dx < buffer.width, dy >= 0, dy < buffer.height else { continue }

                let alphaCell = layer[lx, ly]

                // Fully transparent → preserve destination.
                if alphaCell.alpha <= 0.0 { continue }

                // Fully opaque → overwrite.
                if alphaCell.alpha >= 1.0 {
                    buffer[dx, dy] = Cell(
                        character: alphaCell.glyph.character,
                        style: Style(
                            foreground: alphaCell.foreground,
                            background: alphaCell.background,
                            bold: false,
                            italic: false,
                            underline: false
                        )
                    )
                    continue
                }

                // Partial alpha → blend foreground / background colors
                // with the destination cell's foreground / background.
                let dest = buffer[dx, dy]
                let blendedFg = blend(
                    source: alphaCell.foreground,
                    destination: dest.style.foreground ?? .rgb(0, 0, 0),
                    alpha: alphaCell.alpha
                )
                let blendedBg = blend(
                    source: alphaCell.background,
                    destination: dest.style.background ?? .rgb(0, 0, 0),
                    alpha: alphaCell.alpha
                )
                buffer[dx, dy] = Cell(
                    character: alphaCell.glyph.character,
                    style: Style(
                        foreground: blendedFg,
                        background: blendedBg,
                        bold: false,
                        italic: false,
                        underline: false
                    )
                )
            }
        }
    }

    // MARK: - Color blending

    /// Linear-RGB blend: `result = source * alpha + destination * (1 - alpha)`.
    /// Source / destination Colors that aren't `.rgb` are resolved
    /// via `approximateRGB(of:)`. Output is always `.rgb`.
    static func blend(source: Color, destination: Color, alpha: Double) -> Color {
        let (sr, sg, sb) = approximateRGB(of: source)
        let (dr, dg, db) = approximateRGB(of: destination)
        let inverse = 1.0 - alpha
        let r = UInt8(clamping: Int(Double(sr) * alpha + Double(dr) * inverse))
        let g = UInt8(clamping: Int(Double(sg) * alpha + Double(dg) * inverse))
        let b = UInt8(clamping: Int(Double(sb) * alpha + Double(db) * inverse))
        return .rgb(r, g, b)
    }

    /// Approximate RGB for a `Color`. Named colors map to standard
    /// xterm RGB values; ansi256 uses the 6×6×6 cube formula for the
    /// 16..231 range and grayscale ramp for 232..255; .default returns
    /// black as a conservative approximation.
    static func approximateRGB(of color: Color) -> (UInt8, UInt8, UInt8) {
        switch color {
        case .rgb(let r, let g, let b):
            return (r, g, b)
        case .default:
            return (0, 0, 0)
        case .black:
            return (0, 0, 0)
        case .red:
            return (205, 0, 0)
        case .green:
            return (0, 205, 0)
        case .yellow:
            return (205, 205, 0)
        case .blue:
            return (0, 0, 238)
        case .magenta:
            return (205, 0, 205)
        case .cyan:
            return (0, 205, 205)
        case .white:
            return (229, 229, 229)
        case .gray:
            return (127, 127, 127)
        case .brightRed:
            return (255, 0, 0)
        case .brightGreen:
            return (0, 255, 0)
        case .brightYellow:
            return (255, 255, 0)
        case .brightBlue:
            return (92, 92, 255)
        case .brightMagenta:
            return (255, 0, 255)
        case .brightCyan:
            return (0, 255, 255)
        case .brightWhite:
            return (255, 255, 255)
        case .ansi256(let index):
            return ansi256ToRGB(index)
        }
    }

    /// Standard xterm 256-color → RGB mapping.
    /// 0..15: ANSI base colors (handled by the named-color cases above
    /// when applicable; reachable here only when callers pass them as
    /// .ansi256 directly).
    /// 16..231: 6×6×6 RGB cube. value[i] = i*40+55 if i>0 else 0.
    /// 232..255: 24-step grayscale ramp from 8..238.
    private static func ansi256ToRGB(_ index: UInt8) -> (UInt8, UInt8, UInt8) {
        let idx = Int(index)
        if idx < 16 {
            // Approximate the base ANSI palette.
            let basePalette: [(UInt8, UInt8, UInt8)] = [
                (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
                (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
                (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
                (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)
            ]
            return basePalette[idx]
        } else if idx < 232 {
            let cube = idx - 16
            let r = cube / 36
            let g = (cube / 6) % 6
            let b = cube % 6
            return (cubeStep(r), cubeStep(g), cubeStep(b))
        } else {
            let level = UInt8(8 + (idx - 232) * 10)
            return (level, level, level)
        }
    }

    private static func cubeStep(_ component: Int) -> UInt8 {
        // xterm formula: component 0 → 0, component i (1..5) → i*40+55.
        return component == 0 ? 0 : UInt8(component * 40 + 55)
    }
}
