import Foundation
import TerminalUI

/// The words and glyphs a navigation shows: the arrow for a manoeuvre,
/// a distance as a driver reads it, a time.
public enum NavigationWording {
    /// The arrow for a manoeuvre, one cell wide.
    public static func arrow(for maneuver: Maneuver) -> String {
        switch maneuver.kind {
        case .arrive: return "◎"
        case .roundabout, .rotary, .roundaboutTurn: return "↻"
        case .depart: return "↑"
        default: break
        }
        switch maneuver.direction ?? .straight {
        case .straight: return "↑"
        case .slightLeft: return "↖"
        case .left: return "↰"
        case .sharpLeft: return "↙"
        case .slightRight: return "↗"
        case .right: return "↱"
        case .sharpRight: return "↘"
        case .uturn: return "↶"
        }
    }

    /// A distance rounded as a navigation voice says it — the steps
    /// Mapbox's `DistanceFormatter` rounds to: to 10 m under 100 m, to 50 m
    /// under a kilometre, then tenths of a kilometre — and "now" within a
    /// few metres.
    public static func distance(_ metres: Double) -> String {
        if metres < Rounding.now { return "now" }
        let step = metres < Rounding.tensBelow ? Rounding.ten : Rounding.fifty
        if metres < Rounding.kilometre { return "\(Int((metres / step).rounded() * step)) m" }
        return String(format: "%.1f km", metres / Rounding.kilometre)
    }

    private enum Rounding {
        static let now = 5.0
        static let tensBelow = 100.0
        static let ten = 10.0
        static let fifty = 50.0
        static let kilometre = 1_000.0
    }

    /// A duration in whole minutes, or hours and minutes.
    public static func duration(_ seconds: Double) -> String {
        let minutes = Int((seconds / Clock.secondsPerMinute).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < Clock.minutesPerHour { return "\(minutes) min" }
        return "\(minutes / Clock.minutesPerHour) h \(minutes % Clock.minutesPerHour) min"
    }

    /// A clock time, `HH:mm` in `timeZone`.
    public static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        return (hour < Clock.padBelow ? "0" : "") + "\(hour):" + (minute < Clock.padBelow ? "0" : "") + "\(minute)"
    }

    private enum Clock {
        static let secondsPerMinute = 60.0
        static let minutesPerHour = 60
        static let padBelow = 10
    }

    /// What the street ahead is called: the router's name for the step,
    /// else its sentence — MapKit gives no names.
    public static func street(of step: RouteStep) -> String {
        step.name ?? step.instruction
    }
}

/// The banner across the top of a navigating map: the next manoeuvre's
/// arrow, how far it is and the street it turns onto, the one after it,
/// and the distance, time and arrival left — Apple Maps' and Mapbox's
/// instruction banner, in text.
///
/// ```swift
/// if let session = navigation.session {
///     NavigationBanner(session: session, status: navigation.status, destination: "Public Library")
/// }
/// ```
public struct NavigationBanner: TerminalView {
    /// The session whose progress the banner shows.
    public let session: NavigationSession
    /// The navigation's status, which puts arriving or rerouting in place of the next manoeuvre.
    public let status: NavigationStatus
    /// The destination's name for the arrival line; nil leaves the name out.
    public let destination: String?
    /// Where the route meets the destination, so arriving says how far off
    /// the road it is and on which side.
    public let ends: RouteEnds?
    /// The time zone the arrival time is shown in.
    public let timeZone: TimeZone

    /// A banner for `session` as it stands, with the destination's name and route ends when known.
    public init(session: NavigationSession, status: NavigationStatus, destination: String? = nil,
                ends: RouteEnds? = nil, timeZone: TimeZone = .current) {
        self.session = session
        self.status = status
        self.destination = destination
        self.ends = ends
        self.timeZone = timeZone
    }

    /// "at Public Library, 25 m on your left", or as much of it as is known.
    private var arrivalPlace: String {
        guard let destination else { return "" }
        return " at " + (ends?.arrivalWords(destination: destination) ?? destination)
    }

    @TerminalEnvironment(\.theme) private var theme

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let theme = theme
        VStack(alignment: .leading, spacing: 0) {
            primaryLine(theme)
            secondaryLine(theme)
            summaryLine(theme)
        }
        .padding(.horizontal, 1)
        .background(theme.backgroundRaised)
        .backgroundView { Canvas(opaque: true) { _, _ in }.background(theme.backgroundRaised) }
        .border()
    }

    private func primaryLine(_ theme: any Theme) -> Text {
        if status == .arrived || session.state == .arrived {
            return Text(spans: [TextSpan(" ◎ ", foreground: theme.onPrimary, background: theme.success, bold: true),
                         TextSpan("  You have arrived", foreground: theme.foregroundEmphasis, bold: true),
                         TextSpan(arrivalPlace, foreground: theme.foregroundEmphasis)])
        }
        if status == .rerouting {
            return Text(spans: [TextSpan(" ↺ ", foreground: theme.onPrimary, background: theme.warning, bold: true),
                         TextSpan("  Finding a new route…", foreground: theme.warning, bold: true)])
        }
        if session.needsUTurn {
            return Text(spans: [TextSpan(" ↶ ", foreground: theme.onPrimary, background: theme.primary, bold: true),
                                TextSpan("  Make a U-turn", foreground: theme.foregroundEmphasis, bold: true)])
        }
        guard let index = session.upcomingStepIndex else {
            return Text(TextSpan("Follow the route", foreground: theme.foregroundEmphasis, bold: true))
        }
        let step = session.route.steps[index]
        let instruction = session.maneuvers[index].kind == .arrive && index == session.route.steps.count - 1
            && destination != nil ? "Arrive" + arrivalPlace : step.instruction
        return Text(spans: [
            TextSpan(" \(NavigationWording.arrow(for: session.maneuvers[index])) ", foreground: theme.onPrimary,
                     background: theme.primary, bold: true),
            TextSpan("  \(NavigationWording.distance(session.distanceToManeuver))  ",
                     foreground: theme.foregroundEmphasis, bold: true),
            TextSpan(instruction, foreground: theme.foreground),
        ])
    }

    private func secondaryLine(_ theme: any Theme) -> Text {
        if case .offRoute(let deviation) = session.state, status != .rerouting {
            return Text(TextSpan("Off route by \(NavigationWording.distance(deviation))",
                                 foreground: theme.warning))
        }
        // After a U-turn comes the next manoeuvre; after any other, the
        // one beyond it.
        let thenIndex = (session.upcomingStepIndex ?? session.route.steps.count) + (session.needsUTurn ? 0 : 1)
        guard status != .arrived, session.route.steps.indices.contains(thenIndex), thenIndex > 0 else {
            return Text("")
        }
        let then = session.route.steps[thenIndex]
        return Text(spans: [TextSpan("then ", foreground: theme.foregroundMuted),
                     TextSpan(NavigationWording.arrow(for: session.maneuvers[thenIndex]), foreground: theme.accent,
                              bold: true),
                     TextSpan(" \(then.instruction)", foreground: theme.foregroundSubtle)])
    }

    private func summaryLine(_ theme: any Theme) -> Text {
        let paused = status == .paused ? "  paused" : ""
        guard status != .arrived else { return Text(TextSpan(paused, foreground: theme.warning)) }
        var spans = [TextSpan(NavigationWording.distance(session.distanceRemaining), foreground: theme.accent,
                              bold: true),
                     TextSpan(" · \(NavigationWording.duration(session.durationRemaining))",
                              foreground: theme.foregroundSubtle)]
        if let arrival = session.estimatedArrival {
            spans.append(TextSpan(" · arrive \(NavigationWording.clockTime(arrival, timeZone: timeZone))",
                                  foreground: theme.foregroundSubtle))
        }
        spans.append(TextSpan(paused, foreground: theme.warning))
        return Text(spans: spans)
    }
}
