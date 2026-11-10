import TerminalUI

/// Characters from emptiest to fullest, which a shaded cell is drawn with
/// by how much it stands out from the background.
public struct CharacterRamp: Sendable, Equatable {
    /// The characters, emptiest first; the first is drawn where a cell is
    /// as dim as the background. Each takes one column.
    public let characters: [Character]

    /// A ramp of `characters`, emptiest first. A character that does not
    /// take exactly one column — a wide one, a control — is left out, since
    /// a cell holds one column; fewer than two left stand for the standard
    /// ramp.
    public init(_ characters: String) {
        let usable = characters.filter { $0.displayWidth == 1 }
        self.characters = usable.count >= 2 ? Array(usable) : Array(Self.standardCharacters)
    }

    private static let standardCharacters = " .:-=+*#%@"

    /// ` .:-=+*#%@` — the ten steps of the classic spinning ASCII donut.
    public static let standard = CharacterRamp(standardCharacters)
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
///   colour. `.image(.dots)` draws braille dots throughout.
/// - ``characterRamp(_:)``: a character per cell from a ramp, by how much
///   it stands out from the background, in its shaded colour — the
///   classic spinning donut, legible in any colour depth.
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
/// Outlines mark the silhouette and the creases — where depth or the
/// surface's direction jumps between neighbouring samples. The character
/// styles draw them with edge characters (`|` `-` `_` `/` `\`), dithered
/// braille sets every dot along them, and the image styles darken the
/// creases. The character and braille styles draw them by default; the
/// image styles leave form to the light.
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
        /// mean of their colours, on whatever lies beneath the view.
        case dots
    }

    /// What a braille cell's dots show.
    public enum BrailleFill: Sendable, Equatable {
        /// Dots dithered by brightness: shading in dot density.
        case dithered
        /// Every covered dot: the silhouette.
        case silhouette
        /// The outline and creases only: a drawing in lines.
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
    private(set) var drawsOutlines = true

    /// An image: two pixels a cell in averaged colour, or with
    /// ``ImageFill/dots``, braille dots in it. The default.
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

    /// Whether the samples' edges are needed: for outlines, and for the
    /// braille style that draws nothing else. A braille silhouette sets
    /// every dot an outline could.
    var needsEdges: Bool {
        switch kind {
        case .braille(.edges): true
        case .braille(.silhouette): false
        default: drawsOutlines
        }
    }
}
