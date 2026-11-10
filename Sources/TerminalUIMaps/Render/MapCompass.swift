import Foundation
import TerminalUI

/// A map's bearing as a compass reads it.
struct MapCompassReading: Sendable, Equatable {
    /// Degrees clockwise from north at the top of the map.
    var bearing: Double

    init(bearing: Double) {
        self.bearing = GeoMeasure.normalizedBearing(bearing)
    }

    /// The bearing in whole degrees, 0 to 359.
    var degrees: Int { Int(bearing.rounded()) % Int(Degrees.fullTurn) }

    /// Whether the map is turned off north by a degree it would show.
    var isRotated: Bool { degrees != 0 }

    /// Which way north lies on the screen, as x right and y down: up, the
    /// screen's top, turned back by the bearing.
    var northOnScreen: (x: Double, y: Double) {
        let radians = GeoMeasure.radians(bearing)
        return (-sin(radians), -cos(radians))
    }
}

/// A compass rose on the map, as Apple Maps puts one in its corner: a
/// rounded frame with "N" set on it where north lies on the turned map, an
/// arrow in the middle pointing there, and the bearing in degrees beneath
/// while the map is turned. A tap calls `action` — the app's choice of
/// north up or heading up.
///
/// The rose is box-drawing lines and an arrow, not a drawn circle: a ring a
/// few cells across, in braille, comes out a lumpy octagon, since fonts
/// leave uneven gaps between braille cells. The N and the arrow take the
/// nearest of the eight points; the degrees say the rest.
///
/// ```swift
/// map.overlay(alignment: .topTrailing) {
///     MapCompass(bearing: camera.bearing) { model.compassTapped() }
/// }
/// ```
public struct MapCompass: TerminalView {
    let bearing: Double
    let action: (() -> Void)?

    /// The rose, in cells: a frame three rows high with the arrow in its
    /// middle, and a row beneath for the degrees.
    static let width = 7
    static let height = 3

    /// A compass for a map turned to `bearing`; `action` runs when it is
    /// clicked, as Apple Maps turns a map north up from its compass.
    public init(bearing: Double, action: (() -> Void)? = nil) {
        self.bearing = bearing
        self.action = action
    }

    @TerminalEnvironment(\.theme) private var theme

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let theme = theme
        let reading = MapCompassReading(bearing: bearing)
        let rows = MapCompass.rows(reading)
        VStack(spacing: 0) {
            ForEachWithID(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(spans: MapCompass.spans(row, theme: theme))
            }
            Text(reading.isRotated ? "\(reading.degrees)°" : "")
                .foreground(theme.foregroundEmphasis)
                .frame(width: MapCompass.width, alignment: .center)
        }
        .background(theme.backgroundRaised)
        .onTapGesture { action?() }
    }

    /// The frame's characters, and the eight points round it — each a
    /// direction on the screen, clockwise from up, with the arrow pointing
    /// that way and the cell of the frame the N takes.
    private enum Rose {
        static let rows: [[Character]] = [
            Array("╭─────╮"),
            Array("│     │"),
            Array("╰─────╯"),
        ]
        static let middle = (x: 3, y: 1)
        static let points: [(arrow: Character, x: Int, y: Int)] = [
            ("↑", 3, 0), ("↗", 6, 0), ("→", 6, 1), ("↘", 6, 2),
            ("↓", 3, 2), ("↙", 0, 2), ("←", 0, 1), ("↖", 0, 0),
        ]
        static let fullTurn = 360.0
    }

    /// The rose for `reading`, row by row: north sits on the screen at
    /// minus the bearing, taken to the nearest of the eight points.
    static func rows(_ reading: MapCompassReading) -> [String] {
        let northOnScreen = GeoMeasure.normalizedBearing(Rose.fullTurn - reading.bearing)
        let sector = Rose.fullTurn / Double(Rose.points.count)
        let point = Rose.points[Int((northOnScreen / sector).rounded()) % Rose.points.count]
        var rows = Rose.rows
        rows[Rose.middle.y][Rose.middle.x] = point.arrow
        rows[point.y][point.x] = "N"
        return rows.map { String($0) }
    }

    /// A row in the theme's colours: the frame quiet, the N emphatic, the
    /// arrow in the accent.
    private static func spans(_ row: String, theme: any Theme) -> [TextSpan] {
        row.map { character in
            switch character {
            case "N": TextSpan("N", foreground: theme.foregroundEmphasis, bold: true)
            case _ where Rose.points.contains { $0.arrow == character }:
                TextSpan(String(character), foreground: theme.accent, bold: true)
            default: TextSpan(String(character), foreground: theme.foregroundMuted)
            }
        }
    }
}
