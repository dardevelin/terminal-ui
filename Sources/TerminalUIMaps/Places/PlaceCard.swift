import Foundation
import TerminalUI

/// What a place card says, line by line: worked out from a place, the state
/// of its details and the backend asked, so it is tested without a screen
/// and drawn by ``PlaceCardView``.
///
/// The card never leaves a blank where a detail would go. What the backend
/// gives and this place has is shown; what the backend gives and nobody has
/// recorded for this place is listed as not known; what the backend never
/// gives is said once, by name — "Apple Maps gives no opening hours".
public struct PlaceCardContent: Sendable, Equatable {
    /// How a line is set.
    public enum Tone: Sendable, Equatable {
        case title
        case category
        case body
        /// Good news: open now, wheelchair accessible.
        case positive
        /// Bad news: closed, no access, a failure.
        case negative
        /// What the card cannot say, and why.
        case note
    }

    public struct Line: Sendable, Equatable {
        public var text: String
        public var tone: Tone

        public init(_ text: String, _ tone: Tone) {
            self.text = text
            self.tone = tone
        }
    }

    public var lines: [Line]

    /// The card for `state`'s place, from `provider`, with open-now worked
    /// out at `now` in the place's time zone where the backend gives one,
    /// else in `timeZone`.
    public init(state: PlaceDetailsState, provider: (any PlaceDetails)?, now: Date, timeZone: TimeZone) {
        guard let place = state.place else {
            lines = []
            return
        }
        var lines = [Line(place.name, .title)]
        let sourceName = provider?.sourceName ?? "This map"
        switch state {
        case .idle:
            break
        case .loading:
            Self.addSummary(of: place, to: &lines)
            lines.append(Line("Asking \(sourceName)…", .note))
        case .notFound:
            Self.addSummary(of: place, to: &lines)
            lines.append(Line(provider == nil ? "This map has no details of places"
                                              : "\(sourceName) has no details of this place", .note))
        case .failed(_, let reason):
            Self.addSummary(of: place, to: &lines)
            lines.append(Line("\(sourceName) did not answer: \(reason)", .negative))
        case .loaded(_, let information):
            lines += Self.detailLines(place: place, information: information, provider: provider, now: now,
                                      timeZone: information.timeZone ?? timeZone)
        }
        self.lines = lines
    }

    private static func addSummary(of place: Place, to lines: inout [Line]) {
        lines.append(Line(OSMTags.readable(place.kind), .category))
        if let address = place.address { lines.append(Line(address, .body)) }
    }

    private static func detailLines(place: Place, information: PlaceInformation, provider: (any PlaceDetails)?,
                                    now: Date, timeZone: TimeZone) -> [Line] {
        var lines: [Line] = []
        let category = information.category ?? OSMTags.readable(place.kind)
        let cuisine = information.cuisine.isEmpty ? "" : " · " + information.cuisine.joined(separator: ", ")
        lines.append(Line(category + cuisine, .category))
        if let address = information.address?.line ?? place.address { lines.append(Line(address, .body)) }
        if let hours = information.openingHours {
            lines += hoursLines(hours, now: now, timeZone: timeZone)
        }
        if let phone = information.phone { lines.append(Line(phone, .body)) }
        if let website = information.website { lines.append(Line(website.absoluteString, .body)) }
        if let wheelchair = information.wheelchair {
            lines.append(Line(wheelchair.summary, wheelchair == .no ? .negative : .positive))
        }
        let offered = provider?.fields ?? Set(PlaceDetailField.allCases)
        // Cuisine is asked of places that serve food; a bank has none to
        // be missing.
        let servesFood = information.has(.cuisine) || PointOfInterestCategory.servesFood(kind: place.kind)
        let shown: [PlaceDetailField] = [.openingHours, .phone, .website, .cuisine, .wheelchair]
        let unknown = shown.filter { field in
            offered.contains(field) && !information.has(field) && (field != .cuisine || servesFood)
        }
        if !unknown.isEmpty {
            lines.append(Line("Not known: " + unknown.map(\.title).joined(separator: ", "), .note))
        }
        let never = shown.filter { !offered.contains($0) }
        if !never.isEmpty, let provider {
            lines.append(Line("\(provider.sourceName) gives no " + list(never.map(\.title)), .note))
        }
        return lines
    }

    /// "a, b and c".
    private static func list(_ items: [String]) -> String {
        guard items.count > 1, let last = items.last else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Open or closed now and until when, then the hours as written, a rule
    /// a line.
    static func hoursLines(_ hours: OpeningHours, now: Date, timeZone: TimeZone) -> [Line] {
        var lines: [Line] = []
        if let status = hours.status(at: now, in: timeZone) {
            switch status {
            case .alwaysOpen:
                lines.append(Line("Open 24 hours", .positive))
            case .open(let until):
                lines.append(Line("Open now · closes \(moment(until, after: now, in: timeZone))", .positive))
            case .closed(let until):
                lines.append(Line(until.map { "Closed · opens \(moment($0, after: now, in: timeZone))" }
                                  ?? "Closed all week", .negative))
            }
        } else {
            lines.append(Line("Hours as given; cannot tell if open now", .note))
        }
        if case .alwaysOpen? = hours.status(at: now, in: timeZone) {} else {
            lines += hours.lines.map { Line($0, .body) }
        }
        if hours.ignoresHolidays {
            lines.append(Line("Holiday hours not shown", .note))
        }
        return lines
    }

    /// "18:00" today, "Sat 01:00" another day.
    static func moment(_ date: Date, after now: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let time = String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
        guard !calendar.isDate(date, inSameDayAs: now), let weekday = parts.weekday else { return time }
        return "\(Weekday(calendarWeekday: weekday).shortName) \(time)"
    }
}

extension PointOfInterestCategory {
    /// Whether a place of `kind` — a `poi` class or subclass, or a search
    /// result's type — serves food, so a card asks after its cuisine.
    static func servesFood(kind: String) -> Bool {
        let category = PointOfInterestCategory(class: kind, subclass: kind)
        return category == .food || category == .cafe || category == .bar
    }
}

/// A place card: the lines of a ``PlaceCardContent`` on a raised, opaque
/// ground with a border, and a hint line beneath them.
public struct PlaceCardView: TerminalView {
    public let content: PlaceCardContent
    public let hint: String?
    /// The widest the card grows, in columns, its border included; longer
    /// lines are cut.
    public let maximumWidth: Int

    /// Wide enough for a street address on one line.
    public static let defaultMaximumWidth = 48

    public init(_ content: PlaceCardContent, hint: String? = nil, maximumWidth: Int = PlaceCardView.defaultMaximumWidth) {
        self.content = content
        self.hint = hint
        self.maximumWidth = maximumWidth
    }

    @TerminalEnvironment(\.theme) private var theme

    /// The border's column either side and the padding inside it.
    private static let chromeColumns = 4

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let theme = theme
        let textWidth = max(1, maximumWidth - Self.chromeColumns)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(content.lines.enumerated().map { NumberedLine(id: $0.offset, line: $0.element) }) { numbered in
                Text(TextSpan(Self.clipped(numbered.line.text, to: textWidth),
                              foreground: Self.colour(numbered.line.tone, theme), bold: numbered.line.tone == .title))
            }
            if let hint {
                Text(Self.clipped(hint, to: textWidth)).foreground(theme.foregroundMuted)
            }
        }
        .padding(.horizontal, 1)
        .background(theme.backgroundRaised)
        // `.background` colours only the cells the text writes; an opaque
        // canvas beneath blanks every cell of the card first, so the map
        // does not show through the padding and the short lines' ends.
        .backgroundView {
            Canvas(opaque: true) { _, _ in }.background(theme.backgroundRaised)
        }
        .border()
    }

    /// A line and its place in the card, which a list of lines is keyed by.
    struct NumberedLine: Identifiable {
        let id: Int
        let line: PlaceCardContent.Line
    }

    static func colour(_ tone: PlaceCardContent.Tone, _ theme: any Theme) -> Color {
        switch tone {
        case .title: theme.foregroundEmphasis
        case .category: theme.accent
        case .body: theme.foreground
        case .positive: theme.success
        case .negative: theme.error
        case .note: theme.foregroundMuted
        }
    }

    /// A line cut to `width` columns, an ellipsis marking the cut.
    static func clipped(_ text: String, to width: Int) -> String {
        guard text.displayWidth > width else { return text }
        var kept = ""
        for character in text {
            guard (kept + String(character)).displayWidth < width else { break }
            kept.append(character)
        }
        return kept + "…"
    }
}

/// The map's point-of-interest glyphs and what each means, a kind a line
/// in the kind's colour: what an app shows beside a map of a dense city.
public struct PointOfInterestLegend: TerminalView {
    public let categories: [PointOfInterestCategory]

    public init(_ categories: [PointOfInterestCategory] = PointOfInterestCategory.allCases) {
        self.categories = categories
    }

    @TerminalEnvironment(\.theme) private var theme

    @_documentation(visibility: internal)
    public var body: some TerminalView {
        let theme = theme
        VStack(alignment: .leading, spacing: 0) {
            Text("On the map").bold().foreground(theme.foregroundEmphasis)
            ForEach(categories) { category in
                Text(spans: [TextSpan(category.glyph, foreground: category.colour(in: theme), bold: true),
                      TextSpan(" " + category.title, foreground: theme.foreground)])
            }
        }
        .padding(.horizontal, 1)
        .background(theme.backgroundRaised)
        .backgroundView {
            Canvas(opaque: true) { _, _ in }.background(theme.backgroundRaised)
        }
        .border()
    }
}
