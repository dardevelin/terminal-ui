// Scrollbar thumb geometry. Pure function so the math can be tested
// without firing the renderer, and so future scroll components
// (TextArea, DiffView, List internals) can reuse the same algorithm.
//
// The thumb represents "where in the content the visible viewport
// is." For a viewport of `v` cells over content of `c` cells:
//
//   thumbLength   = max(1, v * v / c)   — proportional to viewport / content
//   trackTravel   = v - thumbLength     — how far the thumb can slide
//   maxOffset     = c - v               — how far the content can scroll
//   thumbStart    = trackTravel * offset / maxOffset   — proportional placement
//
// Returns nil when content fits entirely (`c <= v`) — no scrollbar
// shown is the "no overflow" affordance. Length is clamped to >= 1
// so very long content still shows a one-cell thumb instead of
// vanishing entirely. Offset overflow is clamped to maxOffset so
// over-scroll states don't extend the thumb past the viewport's
// last cell.

/// Compute the thumb start + length for a scrollbar track of
/// `viewport` cells, given total `content` and current `offset`.
/// Returns nil when no scrollbar should be drawn (content fits).
public func scrollbarThumb(viewport: Int, content: Int, offset: Int) -> (start: Int, length: Int)? {
    // Defensive guards: a non-positive viewport can't host a track,
    // and content <= viewport means no overflow.
    guard viewport > 0, content > viewport else { return nil }

    // Proportional length: clamp to >= 1 so very long content still
    // shows a visible thumb. Integer-divide for cell-snap.
    let length = max(1, viewport * viewport / content)

    // Available travel within the track, after thumb takes its cells.
    let trackTravel = viewport - length
    let maxOffset = content - viewport

    // Clamp offset to [0, maxOffset]. Over-scroll (offset > maxOffset)
    // pins the thumb to the bottom; negative offset (shouldn't happen
    // but guards against integer underflow elsewhere) pins to top.
    let clampedOffset = max(0, min(offset, maxOffset))

    // Linear interpolation: at offset=0 thumb is at start=0, at
    // offset=maxOffset thumb is at start=trackTravel.
    let start = maxOffset > 0
        ? trackTravel * clampedOffset / maxOffset
        : 0

    return (start: start, length: length)
}
