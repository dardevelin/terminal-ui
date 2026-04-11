/// A rendering layer with its own cell buffer and position.
public struct Layer {
    public var buffer: CellBuffer
    public var x: Int
    public var y: Int
    public var style: LayerStyle

    public enum LayerStyle {
        /// Opaque — all cells in the buffer replace whatever is below
        case opaque
        /// Transparent — only non-empty cells replace what's below
        case transparent
        /// Dim — modifies the cells below (changes foreground color)
        case dim(Color)
    }

    public init(width: Int, height: Int, x: Int = 0, y: Int = 0, style: LayerStyle = .opaque) {
        self.buffer = CellBuffer(width: width, height: height)
        self.x = x
        self.y = y
        self.style = style
    }
}

/// Composites multiple layers into a final cell buffer.
/// Layers are applied bottom-to-top. Higher layers occlude lower ones
/// within their bounds.
public enum Compositor {

    /// Merge all layers into the output buffer, bottom to top.
    public static func composite(layers: [Layer], into output: inout CellBuffer) {
        for layer in layers {
            switch layer.style {
            case .opaque:
                // Every cell from this layer replaces the output
                for ly in 0..<layer.buffer.height {
                    let outY = layer.y + ly
                    guard outY >= 0, outY < output.height else { continue }
                    for lx in 0..<layer.buffer.width {
                        let outX = layer.x + lx
                        guard outX >= 0, outX < output.width else { continue }
                        output[outX, outY] = layer.buffer[lx, ly]
                    }
                }

            case .transparent:
                // Only non-empty cells from this layer replace the output
                for ly in 0..<layer.buffer.height {
                    let outY = layer.y + ly
                    guard outY >= 0, outY < output.height else { continue }
                    for lx in 0..<layer.buffer.width {
                        let outX = layer.x + lx
                        guard outX >= 0, outX < output.width else { continue }
                        let cell = layer.buffer[lx, ly]
                        if cell != .empty {
                            output[outX, outY] = cell
                        }
                    }
                }

            case .dim(let color):
                // Modify existing cells — change foreground, don't replace content
                for ly in 0..<layer.buffer.height {
                    let outY = layer.y + ly
                    guard outY >= 0, outY < output.height else { continue }
                    for lx in 0..<layer.buffer.width {
                        let outX = layer.x + lx
                        guard outX >= 0, outX < output.width else { continue }
                        var cell = output[outX, outY]
                        cell.style.foreground = color
                        cell.style.bold = false
                        output[outX, outY] = cell
                    }
                }
            }
        }
    }
}
