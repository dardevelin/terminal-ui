/// A rendering layer with its own cell buffer and position.
///
/// Layers enable z-ordered compositing for modals and overlays.
/// Each layer renders into an isolated CellBuffer, then layers
/// are composited bottom-to-top into the final output buffer.
public struct Layer {
    public var buffer: CellBuffer
    public var x: Int
    public var y: Int
    public var style: LayerStyle
    public var previousBuffer: CellBuffer?
    public var dirtyRect: DirtyRegion

    public enum LayerStyle {
        /// Replace all cells in the destination (standard app content).
        case opaque
        /// Skip empty cells — only write cells that have content.
        /// Used for floating windows and overlays that sit atop background.
        case transparent
        /// Reduce color intensity of the destination (dim the background).
        /// Takes a fallback color for terminals that don't render dimmed RGB.
        /// Uses manual color reduction rather than SGR 2 (faint), which is
        /// unsupported or inconsistent across many terminal emulators.
        case dim(Color)
    }

    public enum DirtyRegion: Equatable {
        /// Entire layer needs recompositing
        case full
        /// Only this rect changed
        case rect(x: Int, y: Int, width: Int, height: Int)
        /// Nothing changed — skip this layer
        case clean
    }

    public init(width: Int, height: Int, x: Int = 0, y: Int = 0, style: LayerStyle = .opaque) {
        self.buffer = CellBuffer(width: width, height: height)
        self.x = x
        self.y = y
        self.style = style
        self.previousBuffer = nil
        self.dirtyRect = .full
    }

    /// Compare against previous buffer and compute dirty region.
    public mutating func computeDirtyRegion() {
        guard let prev = previousBuffer,
              prev.width == buffer.width,
              prev.height == buffer.height else {
            dirtyRect = .full
            return
        }

        var minX = buffer.width, minY = buffer.height
        var maxX = -1, maxY = -1

        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                if buffer[x, y] != prev[x, y] {
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        if maxX < 0 {
            dirtyRect = .clean
        } else {
            dirtyRect = .rect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

    /// Snapshot current buffer as previous for next frame's delta.
    public mutating func snapshotBuffer() {
        previousBuffer = buffer
    }
}

/// Composites multiple layers into a final cell buffer.
/// Supports full and delta compositing.
public enum Compositor {

    /// Full composite — merge all layers, bottom to top.
    public static func composite(layers: [Layer], into output: inout CellBuffer) {
        for layer in layers {
            compositeLayer(layer, into: &output, region: .full)
        }
    }

    /// Delta composite — only recomposite dirty regions.
    /// Layers that haven't changed are skipped entirely.
    /// Returns the bounding rect of all changes in output coordinates, or nil if nothing changed.
    public static func deltaComposite(layers: inout [Layer], into output: inout CellBuffer) -> (x: Int, y: Int, width: Int, height: Int)? {
        // Compute dirty regions for each layer
        for i in 0..<layers.count {
            layers[i].computeDirtyRegion()
        }

        // Find union of all dirty regions in output space
        var dirtyMinX = output.width, dirtyMinY = output.height
        var dirtyMaxX = -1, dirtyMaxY = -1

        for layer in layers {
            switch layer.dirtyRect {
            case .full:
                // Full layer dirty — entire layer bounds are dirty in output space
                dirtyMinX = min(dirtyMinX, layer.x)
                dirtyMinY = min(dirtyMinY, layer.y)
                dirtyMaxX = max(dirtyMaxX, layer.x + layer.buffer.width - 1)
                dirtyMaxY = max(dirtyMaxY, layer.y + layer.buffer.height - 1)

            case .rect(let rx, let ry, let rw, let rh):
                // Partial dirty — translate to output space
                dirtyMinX = min(dirtyMinX, layer.x + rx)
                dirtyMinY = min(dirtyMinY, layer.y + ry)
                dirtyMaxX = max(dirtyMaxX, layer.x + rx + rw - 1)
                dirtyMaxY = max(dirtyMaxY, layer.y + ry + rh - 1)

            case .clean:
                continue
            }
        }

        // Nothing dirty across all layers
        if dirtyMaxX < 0 { return nil }

        // Clamp to output bounds
        dirtyMinX = max(0, dirtyMinX)
        dirtyMinY = max(0, dirtyMinY)
        dirtyMaxX = min(output.width - 1, dirtyMaxX)
        dirtyMaxY = min(output.height - 1, dirtyMaxY)

        let dirtyW = dirtyMaxX - dirtyMinX + 1
        let dirtyH = dirtyMaxY - dirtyMinY + 1

        // Recomposite only the dirty region from ALL layers
        // (because higher layers may occlude lower layers in the dirty area)
        let outputRegion = Layer.DirtyRegion.rect(x: dirtyMinX, y: dirtyMinY, width: dirtyW, height: dirtyH)
        for layer in layers {
            compositeLayer(layer, into: &output, region: outputRegion)
        }

        // Snapshot all layers for next frame
        for i in 0..<layers.count {
            layers[i].snapshotBuffer()
        }

        return (x: dirtyMinX, y: dirtyMinY, width: dirtyW, height: dirtyH)
    }

    // MARK: - Internal

    static func compositeLayer(_ layer: Layer, into output: inout CellBuffer, region: Layer.DirtyRegion) {
        // Determine the output rect to process
        let (startX, startY, endX, endY): (Int, Int, Int, Int)

        switch region {
        case .full:
            startX = max(0, layer.x)
            startY = max(0, layer.y)
            endX = min(output.width, layer.x + layer.buffer.width)
            endY = min(output.height, layer.y + layer.buffer.height)
        case .rect(let rx, let ry, let rw, let rh):
            // Intersect the dirty rect with the layer's bounds in output space
            startX = max(rx, layer.x)
            startY = max(ry, layer.y)
            endX = min(rx + rw, min(output.width, layer.x + layer.buffer.width))
            endY = min(ry + rh, min(output.height, layer.y + layer.buffer.height))
        case .clean:
            return
        }

        guard startX < endX, startY < endY else { return }

        switch layer.style {
        case .opaque:
            for outY in startY..<endY {
                let ly = outY - layer.y
                for outX in startX..<endX {
                    let lx = outX - layer.x
                    output[outX, outY] = layer.buffer[lx, ly]
                }
            }

        case .transparent:
            for outY in startY..<endY {
                let ly = outY - layer.y
                for outX in startX..<endX {
                    let lx = outX - layer.x
                    let cell = layer.buffer[lx, ly]
                    if cell != .empty {
                        output[outX, outY] = cell
                    }
                }
            }

        case .dim(let tint):
            for outY in startY..<endY {
                for outX in startX..<endX {
                    var cell = output[outX, outY]
                    // Dim: shift bright colors to their dark counterparts, disable bold.
                    // Preserves hue but reduces intensity.
                    if let fg = cell.style.foreground {
                        cell.style.foreground = fg.dimmed(fallback: tint)
                    } else {
                        cell.style.foreground = tint
                    }
                    cell.style.bold = false
                    output[outX, outY] = cell
                }
            }
        }
    }
}
