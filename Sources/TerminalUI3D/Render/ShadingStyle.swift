/// Characters from emptiest to fullest, which a shaded cell is drawn with
/// by how much it stands out from the background.
public struct CharacterRamp: Sendable, Equatable {
    /// The characters, emptiest first; the first is drawn where a cell is
    /// as dim as the background. Each must take one column.
    public let characters: [Character]

    /// A ramp of `characters`, emptiest first. Fewer than two stand for
    /// the standard ramp.
    public init(_ characters: String) {
        let unique = Array(characters)
        self.characters = unique.count >= 2 ? unique : CharacterRamp.standard.characters
    }

    /// ` .:-=+*#%@` — the ten steps of the classic spinning ASCII donut.
    public static let standard = CharacterRamp(" .:-=+*#%@")
    /// Seventy steps (Paul Bourke, "Character representation of grey scale
    /// images", 1997): finer shading where cells are many.
    public static let detailed = CharacterRamp(
        " .'`^\",:;Il!i><~+_-?][}{1)(|\\/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$")
    /// Five steps of block shading, ` ░▒▓█`.
    public static let blocks = CharacterRamp(" \u{2591}\u{2592}\u{2593}\u{2588}")
}

/// How a ``SceneView`` turns its rendered scene into cells.
///
/// The scene is always rendered at braille resolution, eight samples to a
/// cell, and each style resolves those samples differently:
///
/// - ``image(_:)``, the default: an image. Each half cell is the mean of
///   its four samples' lit colours, mixed in linear light, so shading is
///   continuous; where the shape's edge crosses a cell, the part it leaves
///   bare is mixed toward the background, anti-aliasing the outline — or,
///   over a terminal ground no program can know, the cell keeps the edge's
///   shape in braille dots, a dot for each sample covered, in their mean
///   colour.
/// - ``characterRamp(_:)``: a character per cell from a ramp, by how much
///   it stands out from the background, in its shaded colour — the
///   classic donut, legible in any colour depth.
/// - ``halfBlock``: two true-colour pixels per cell, each the average of
///   its four samples' colours in linear light, the part the shape leaves
///   bare mixed toward the background — anti-aliased wherever the
///   background is a colour the renderer knows.
/// - ``braille(_:)``: eight dots per cell — a dithered silhouette, a plain
///   one, or the edges only — in the cell's shaded colour.
/// - ``hybrid(_:)``: the shaded colour as the cell's background, with a
///   ramp or edge character over it in a colour pushed away from it: the
///   most contrast a cell can carry.
///
/// Outlines draw the silhouette and the creases — where depth or the
/// surface's direction jumps — with edge characters (`|` `-` `/` `\`) in
/// the character styles, and darker or brighter samples in the others. The
/// character styles draw them by default; the image styles leave form to
/// the light.
///
/// ```swift
/// SceneView(scene)                       // .image()
/// SceneView(scene, shading: .hybrid())
/// SceneView(scene, shading: .characterRamp(.detailed).outlines(false))
/// ```
public struct ShadingStyle: Sendable, Equatable {
    /// How an image fills the cells the shape covers.
    public enum ImageFill: Sendable, Equatable {
        /// Solid: two pixels a cell, dots only at an edge over a ground no
        /// program can know.
        case solid
        /// Braille dots throughout, a dot for each sample covered, in the
        /// mean of their colours, on whatever lies beneath the view — the
        /// Codex CLI's look.
        case dots
    }

    /// What a braille cell's dots show.
    public enum BrailleFill: Sendable, Equatable {
        /// Dots dithered by brightness: shading in dot density.
        case dithered
        /// Every covered dot: the silhouette.
        case silhouette
        /// The outline and creases only: a wireframe-like drawing.
        case edges
    }

    enum Kind: Sendable, Equatable {
        case image(ImageFill)
        case characterRamp(CharacterRamp)
        case halfBlock
        case braille(BrailleFill)
        case hybrid(CharacterRamp)
    }

    let kind: Kind
    /// Whether silhouettes and creases are drawn.
    public private(set) var drawsOutlines = true

    /// An image in braille dots and averaged colour: the default.
    public static func image(_ fill: ImageFill = .solid) -> ShadingStyle {
        ShadingStyle(kind: .image(fill), drawsOutlines: false)
    }

    /// A ramp character per cell in its shaded colour.
    public static func characterRamp(_ ramp: CharacterRamp = .standard) -> ShadingStyle {
        ShadingStyle(kind: .characterRamp(ramp))
    }

    /// Two shaded true-colour pixels per cell.
    public static let halfBlock = ShadingStyle(kind: .halfBlock, drawsOutlines: false)

    /// Eight dots per cell, showing `fill`.
    public static func braille(_ fill: BrailleFill = .dithered) -> ShadingStyle {
        ShadingStyle(kind: .braille(fill))
    }

    /// A shaded background with a ramp or edge character over it.
    public static func hybrid(_ ramp: CharacterRamp = .standard) -> ShadingStyle {
        ShadingStyle(kind: .hybrid(ramp))
    }

    /// This style, drawing outlines or not.
    public func outlines(_ enabled: Bool) -> ShadingStyle {
        var style = self
        style.drawsOutlines = enabled
        return style
    }

    /// A short name for the style — `image`, `ramp`, `half-block`,
    /// `braille`, `hybrid` — for a control that switches between them.
    public var name: String {
        switch kind {
        case .image(let fill): fill == .solid ? "image" : "image dots"
        case .characterRamp: "ramp"
        case .halfBlock: "half-block"
        case .braille(let fill):
            switch fill {
            case .dithered: "braille"
            case .silhouette: "braille silhouette"
            case .edges: "braille edges"
            }
        case .hybrid: "hybrid"
        }
    }
}
