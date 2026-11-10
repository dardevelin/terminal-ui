import Observation

/// Where the details of the place on show have got to.
public enum PlaceDetailsState: Sendable, Equatable {
    /// No place on show.
    case idle
    case loading(Place)
    case loaded(Place, PlaceInformation)
    /// The backend does not know the place.
    case notFound(Place)
    case failed(Place, String)

    /// The place on show, whatever its details' state.
    public var place: Place? {
        switch self {
        case .idle: nil
        case .loading(let place), .loaded(let place, _), .notFound(let place), .failed(let place, _): place
        }
    }
}

/// The details of the place a map has selected, fetched from a
/// ``PlaceDetails`` backend as a task — a model a place card reads, and a
/// test drives without a screen.
///
/// Showing a place cancels the fetch for the one before; what each fetch
/// found is kept, so going back to a place shows it at once. A new backend
/// forgets all of it.
///
/// ```swift
/// let loader = PlaceDetailsLoader(provider: NominatimPlaceDetails(userAgent: agent))
/// loader.show(place)
/// PlaceCardView(PlaceCardContent(state: loader.state, provider: loader.provider, now: .now, timeZone: .current))
/// ```
@MainActor
@Observable
public final class PlaceDetailsLoader {
    public private(set) var state = PlaceDetailsState.idle
    /// The backend asked; nil where the app has none.
    @ObservationIgnored public private(set) var provider: (any PlaceDetails)?

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var found: [Place: PlaceInformation?] = [:]

    /// A loader asking `provider`. Not isolated, so an app's model can make
    /// one as it is made.
    public nonisolated init(provider: (any PlaceDetails)?) {
        self.provider = provider
    }

    isolated deinit {
        task?.cancel()
    }

    /// Show `place`: its details when known, else fetched.
    public func show(_ place: Place) {
        guard state.place != place || isUnsettled else { return }
        task?.cancel()
        guard let provider else {
            state = .notFound(place)
            return
        }
        if let known = found[place] {
            state = known.map { .loaded(place, $0) } ?? .notFound(place)
            return
        }
        state = .loading(place)
        task = Task { [weak self] in
            do {
                let information = try await PlaceDetailsLoader.fetch(place, from: provider)
                guard !Task.isCancelled, let self, self.state == .loading(place) else { return }
                self.found[place] = .some(information)
                self.state = information.map { .loaded(place, $0) } ?? .notFound(place)
            } catch {
                guard !Task.isCancelled, let self, self.state == .loading(place) else { return }
                self.state = .failed(place, String(describing: error))
            }
        }
    }

    /// Whether the place on show failed to load, and so may be asked again.
    private var isUnsettled: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Show nothing.
    public func clear() {
        task?.cancel()
        state = .idle
    }

    /// Ask another backend from now on.
    public func replaceProvider(_ newProvider: (any PlaceDetails)?) {
        task?.cancel()
        provider = newProvider
        found.removeAll()
        if let place = state.place {
            state = .idle
            show(place)
        }
    }

    @concurrent
    private nonisolated static func fetch(_ place: Place, from provider: any PlaceDetails) async throws
        -> PlaceInformation? {
        try await provider.details(for: place)
    }
}
