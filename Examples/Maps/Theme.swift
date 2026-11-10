import TerminalUI

/// The app's two themes. Each states its ground, its text and the hues the
/// map's roles read (MapStyle.swift: water in `info`, parks in `success`,
/// the main roads in `warning`, motorways in `attention`, markers and
/// routes in `accent`), and the framework derives the quiet shades the map
/// fills its areas with by mixing each toward the ground.
struct MapsTheme: Theme {
    var background: Color
    var foreground: Color
    var foregroundEmphasis: Color
    var accent: Color
    var primary: Color
    var warning: Color
    var attention: Color
    var info: Color
    var success: Color
    var error: Color

    /// A night map: a blue-black ground, chalk text.
    static let dark = MapsTheme(
        background: .rgb(18, 22, 30), foreground: .rgb(200, 206, 214), foregroundEmphasis: .rgb(244, 246, 250),
        accent: .rgb(255, 96, 112), primary: .rgb(255, 96, 112), warning: .rgb(226, 184, 92),
        attention: .rgb(240, 138, 64), info: .rgb(92, 156, 230), success: .rgb(96, 176, 104),
        error: .rgb(240, 90, 90))

    /// A paper map: a warm white ground, ink text.
    static let light = MapsTheme(
        background: .rgb(246, 243, 236), foreground: .rgb(52, 56, 64), foregroundEmphasis: .rgb(16, 18, 22),
        accent: .rgb(214, 40, 70), primary: .rgb(214, 40, 70), warning: .rgb(196, 132, 20),
        attention: .rgb(214, 100, 24), info: .rgb(40, 110, 200), success: .rgb(64, 140, 72),
        error: .rgb(200, 40, 40))
}
