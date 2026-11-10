import TerminalUI

extension MapRole {
    /// The colour the role is drawn in under `theme`: a role of the
    /// theme's, never a colour of the map's own, so the map follows the
    /// app into dark and light alike.
    ///
    /// Areas take the quiet roles — the subtle status shades and the raised
    /// grounds — so they read as ground beneath everything else. Lines and
    /// labels take legible foregrounds: water in the info hue, the main
    /// roads in the warning hue a road atlas draws them in, the rest in
    /// steps of the foreground ramp by importance.
    func colour(in theme: any Theme) -> Color {
        switch self {
        case .landcover, .park: theme.successSubtle
        case .landuse: theme.backgroundRaised
        case .water: theme.infoSubtle
        case .building: theme.backgroundOverlay
        case .waterway: theme.info
        case .boundary, .path: theme.foregroundFaint
        case .serviceRoad, .rail: theme.foregroundMuted
        case .minorRoad: theme.foregroundSubtle
        case .tertiary, .secondary: theme.foreground
        case .primary, .trunk: theme.warning
        case .motorway: theme.attention
        case .waterLabel, .lakeLabel: theme.info
        case .houseNumberLabel: theme.foregroundFaint
        case .roadLabel: theme.foregroundMuted
        case .poiLabel: theme.foregroundSubtle
        case .suburbLabel, .villageLabel: theme.foreground
        case .townLabel, .cityLabel: theme.foregroundEmphasis
        case .regionLabel, .countryLabel: theme.foregroundMuted
        }
    }

    /// Whether the role's labels are set bold: the names of the places a
    /// reader looks for first.
    var isBoldLabel: Bool {
        switch self {
        case .townLabel, .cityLabel, .countryLabel: true
        default: false
        }
    }
}
