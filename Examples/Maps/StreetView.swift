import Foundation
import TerminalUI
import TerminalUIMaps

extension Backend {
    /// Where a Mapillary token is read from: the app's choice, which a
    /// library never makes for it.
    static let mapillaryTokenVariable = "MAPILLARY_ACCESS_TOKEN"

    /// The street imagery each preset offers, its default first: the
    /// sample town's own, Apple's Look Around on Apple, and everywhere
    /// Panoramax, with Mapillary where `MAPILLARY_ACCESS_TOKEN` holds a
    /// token.
    var streetImagery: [any StreetImagery] {
        var open: [any StreetImagery] = [PanoramaxImagery(userAgent: Backend.userAgent)]
        if let token = ProcessInfo.processInfo.environment[Backend.mapillaryTokenVariable], !token.isEmpty {
            open.append(MapillaryImagery(token: token, userAgent: Backend.userAgent))
        }
        switch preset {
        case .sample:
            return [SampleStreetImagery()]
        case .apple:
            #if canImport(MapKit)
            return [LookAroundImagery()] + open
            #else
            return open
            #endif
        case .openStreetMap, .offline:
            return open
        }
    }
}

extension MapsModel {
    /// `v`: street view of the place pinned, else of the map's middle.
    @MainActor
    func openStreetView() {
        streetImageryIndex = min(streetImageryIndex, max(backend.streetImagery.count - 1, 0))
        if street.imageryName != backend.streetImagery[streetImageryIndex].name {
            street.setImagery(backend.streetImagery[streetImageryIndex])
        }
        street.look(at: selected?.coordinate ?? camera.center)
        open(.streetView)
    }

    /// The backend's next street imagery service, looking again where the
    /// last one looked.
    @MainActor
    func nextStreetImagery() {
        let services = backend.streetImagery
        guard services.count > 1 else { return }
        streetImageryIndex = (streetImageryIndex + 1) % services.count
        let place = street.image?.coordinate ?? selected?.coordinate ?? camera.center
        street.setImagery(services[streetImageryIndex])
        street.look(at: place)
    }

    /// A new backend's first street imagery.
    @MainActor
    func resetStreetImagery() {
        streetImageryIndex = 0
        if let first = backend.streetImagery.first { street.setImagery(first) }
    }
}

/// The street view panel: the library's, with the key that changes the
/// service.
struct StreetViewSidePanel: TerminalView {
    let model: MapsModel
    let theme: any Theme

    var body: some TerminalView {
        let count = model.backend.streetImagery.count
        VStack(alignment: .leading, spacing: 0) {
            StreetViewPanel(model: model.street)
                .onKeyPress { event in
                    guard event.key == .character("i"), count > 1 else { return .ignored }
                    MainActor.assumeIsolated { maps.nextStreetImagery() }
                    return .handled
                }
            Text(count > 1 ? "i other service · Esc close" : "Esc close").foreground(theme.foregroundMuted)
        }
    }
}
