import Foundation

/// Name search over a list of places, for the searches that hold their
/// places themselves (the sample town, an offline pack): case and accents
/// ignored, a name that starts with the query before one with a word that
/// does, before one that merely contains it, and within each, the nearest
/// to the region in view first.
struct PlaceMatcher: Sendable {
    let places: [Place]
    private let foldedNames: [String]

    /// How many results a search returns at most.
    static let resultLimit = 20

    init(places: [Place]) {
        self.places = places
        self.foldedNames = places.map { PlaceMatcher.fold($0.name) }
    }

    func search(_ query: String, near region: GeoRect?) -> [Place] {
        let needle = PlaceMatcher.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        let centre = region.map { WebMercator.project($0.center) }
        var ranked: [(rank: Int, distance: Double, index: Int)] = []
        for (index, name) in foldedNames.enumerated() {
            guard let rank = PlaceMatcher.rank(name, needle) else { continue }
            var distance = 0.0
            if let centre {
                let point = WebMercator.project(places[index].coordinate)
                distance = (point.x - centre.x) * (point.x - centre.x) + (point.y - centre.y) * (point.y - centre.y)
            }
            ranked.append((rank, distance, index))
        }
        ranked.sort { ($0.rank, $0.distance, $0.index) < ($1.rank, $1.distance, $1.index) }
        return ranked.prefix(PlaceMatcher.resultLimit).map { places[$0.index] }
    }

    /// 0 for a name that starts with the query, 1 for one with a word that
    /// does, 2 for one that contains it, nil for no match.
    private static func rank(_ name: String, _ needle: String) -> Int? {
        if name.hasPrefix(needle) { return 0 }
        guard let range = name.range(of: needle) else { return nil }
        guard range.lowerBound > name.startIndex else { return 0 }
        let before = name[name.index(before: range.lowerBound)]
        return before.isLetter || before.isNumber ? 2 : 1
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
