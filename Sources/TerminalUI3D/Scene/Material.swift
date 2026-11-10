import TerminalUI

/// What a surface looks like: its colour, or a gradient a vertex's tint
/// chooses along, and how it takes the light.
///
/// Colours are a theme's roles, read in the view's body, or colours a
/// caller chooses; the renderer shades them by the light, in Oklab, and
/// fogs them toward the background.
///
/// ```swift
/// @TerminalEnvironment(\.theme) var theme
/// …
/// let faces = Material(theme.accent, specular: 0.6)
/// let ground = Material(gradient: [theme.info, theme.success, theme.foregroundMuted, theme.foreground])
/// ```
public struct Material: Sendable, Equatable {
    /// The surface's colour: one, or the stops of a gradient a vertex's
    /// tint places it along, 0 at the first and 1 at the last.
    public var colours: [Color]
    /// How bright the shine of the lights is on it, 0 for none: about 0.2
    /// for stone, 0.8 for glazed paint.
    public var specular: Double
    /// How tight that shine is: the Blinn–Phong exponent, higher for a
    /// smaller, sharper highlight.
    public var shininess: Double
    /// Light the surface gives off itself, 0 to 1: a lit window, a marker
    /// that must read in the dark.
    public var emission: Double
    /// Whether its triangles are drawn from behind as well as from the front.
    public var isDoubleSided: Bool

    /// A surface of `colour`.
    public init(_ colour: Color, specular: Double = Material.defaultSpecular,
                shininess: Double = Material.defaultShininess, emission: Double = 0,
                isDoubleSided: Bool = false) {
        self.init(gradient: [colour], specular: specular, shininess: shininess,
                  emission: emission, isDoubleSided: isDoubleSided)
    }

    /// A surface coloured along `gradient` by each vertex's tint: the first
    /// colour at 0, the last at 1, mixed in Oklab between.
    public init(gradient: [Color], specular: Double = Material.defaultSpecular,
                shininess: Double = Material.defaultShininess, emission: Double = 0,
                isDoubleSided: Bool = false) {
        self.colours = gradient
        self.specular = specular
        self.shininess = shininess
        self.emission = emission
        self.isDoubleSided = isDoubleSided
    }

    /// A modest shine, for a surface that says nothing else.
    public static let defaultSpecular = 0.35
    /// A highlight about the size of a painted surface's.
    public static let defaultShininess = 24.0
}
