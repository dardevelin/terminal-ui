import Foundation
import Observation
import TerminalUIIO

/// Street view's state, testable without a screen: the image shown, its
/// photo, the images either side along its street, and where a look or a
/// step has got to.
///
/// ``look(at:)`` finds the image nearest a place; ``step(_:)`` walks to the
/// next or previous along the street. Each starts a task and returns it,
/// so a test awaits the answer rather than a clock; a look or step that a
/// later one overtakes is cancelled, and its answer dropped.
///
/// ```swift
/// let street = StreetViewModel(imagery: PanoramaxImagery(userAgent: "MyMaps/1.0 (me@example.com)"))
/// street.look(at: place.coordinate)
/// StreetViewPanel(model: street)
/// ```
@MainActor
@Observable
public final class StreetViewModel {
    /// Where a look or a step has got to.
    public enum Status: Sendable, Equatable {
        /// Nothing asked yet, or the service just changed.
        case idle
        /// Looking for the image nearest a place.
        case searching
        /// An image found, its photo on its way.
        case loadingPhoto
        /// The image's photo is shown.
        case showing
        /// The service has no image near the place.
        case nothingNearby
        /// The look or step failed, for the reason given.
        case failed(String)
    }

    /// Which way along the street to step.
    public enum Step: Sendable {
        /// To the next image along the street.
        case forward
        /// To the previous image along the street.
        case back
    }

    /// The service images come from; ``setImagery(_:)`` changes it.
    @ObservationIgnored public private(set) var imagery: any StreetImagery
    /// The service's name, observed, for the panel's heading.
    public private(set) var imageryName: String
    /// The image shown; nil before a look finds one.
    public private(set) var image: StreetImage?
    /// The shown image's photo; nil while it loads.
    public private(set) var photo: ImageBuffer?
    /// The images either side of the shown one, once they are known.
    public private(set) var neighbours = StreetImageNeighbours.none
    /// Where the latest look or step has got to.
    public private(set) var status = Status.idle
    /// The compass bearing a step walks where images have no sequence of
    /// their own: the image's heading when it has one, else as turned.
    public private(set) var walkingBearing = CompassBearing.north

    /// How far from the place a look searches, in metres: a street's width
    /// and a little more, so the photo is of the street asked about.
    static let searchRadius = 60.0
    /// How far ``turn(by:)`` turns at a press: an eighth of the compass.
    static let turnStep = 45.0

    @ObservationIgnored private var generation = 0
    /// The look, step or turn under way, cancelled by the next.
    @ObservationIgnored private var current: Task<Void, Never>?

    /// A street view showing nothing yet, with images from `imagery`.
    public init(imagery: any StreetImagery) {
        self.imagery = imagery
        imageryName = imagery.name
    }

    /// Use another service; what was shown is cleared.
    public func setImagery(_ newImagery: any StreetImagery) {
        imagery = newImagery
        imageryName = newImagery.name
        generation += 1
        current?.cancel()
        image = nil
        photo = nil
        neighbours = .none
        status = .idle
    }

    /// Show the image nearest `coordinate`.
    @discardableResult
    public func look(at coordinate: GeoCoordinate) -> Task<Void, Never> {
        generation += 1
        let generation = generation, imagery = imagery
        status = .searching
        return replaceCurrent(Task { [weak self] in
            do {
                let found = try await imagery.images(near: coordinate, within: Self.searchRadius)
                guard let self, self.generation == generation else { return }
                guard let nearest = found.first else {
                    self.image = nil
                    self.photo = nil
                    self.neighbours = .none
                    self.status = .nothingNearby
                    return
                }
                await self.show(nearest, generation: generation)
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.status = .failed(String(describing: error))
            }
        })
    }

    /// Cancel the task under way and keep `task` as the one now.
    private func replaceCurrent(_ task: Task<Void, Never>) -> Task<Void, Never> {
        current?.cancel()
        current = task
        return task
    }

    /// Walk to the next or the previous image along the street; nothing
    /// where there is none that way.
    @discardableResult
    public func step(_ direction: Step) -> Task<Void, Never>? {
        let target = direction == .forward ? neighbours.next : neighbours.previous
        guard let target else { return nil }
        if direction == .back, image?.heading == nil {
            // Walking back on a bearing faces the other way.
            walkingBearing = CompassBearing.normalised(walkingBearing + CompassBearing.south)
        }
        generation += 1
        let generation = generation
        return replaceCurrent(Task { [weak self] in await self?.show(target, generation: generation) })
    }

    /// Turn the bearing steps walk, for imagery without sequences: the
    /// neighbours are asked again on the new bearing.
    @discardableResult
    public func turn(by degrees: Double) -> Task<Void, Never>? {
        walkingBearing = CompassBearing.normalised(walkingBearing + degrees)
        guard let image else { return nil }
        generation += 1
        let generation = generation, imagery = imagery, bearing = walkingBearing
        return replaceCurrent(Task { [weak self] in
            let found = (try? await imagery.neighbours(of: image, along: bearing)) ?? .none
            guard let self, self.generation == generation else { return }
            self.neighbours = found
        })
    }

    /// Show `image`: its photo, then its neighbours.
    private func show(_ shown: StreetImage, generation: Int) async {
        guard self.generation == generation else { return }
        image = shown
        photo = nil
        neighbours = .none
        status = .loadingPhoto
        if let heading = shown.heading { walkingBearing = CompassBearing.normalised(heading) }
        let imagery = imagery, bearing = walkingBearing
        do {
            async let photo = imagery.photo(of: shown)
            async let neighbours = imagery.neighbours(of: shown, along: bearing)
            let loaded = try await photo
            guard self.generation == generation else { return }
            self.photo = loaded
            status = .showing
            let around = (try? await neighbours) ?? .none
            guard self.generation == generation else { return }
            self.neighbours = around
        } catch {
            guard self.generation == generation, !Task.isCancelled else { return }
            status = .failed(String(describing: error))
        }
    }
}
