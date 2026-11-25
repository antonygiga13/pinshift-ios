import Foundation
import MapKit

struct ResolvedPlace {
    let title: String
    let subtitle: String
    let coordinate: CLLocationCoordinate2D
}

@MainActor
final class PlaceSearchService: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query: String = "" {
        didSet {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                completions = []
            } else {
                completer.queryFragment = trimmed
            }
        }
    }

    @Published var completions: [MKLocalSearchCompletion] = []
    @Published var isSearching: Bool = false

    private let completer: MKLocalSearchCompleter

    override init() {
        self.completer = MKLocalSearchCompleter()
        super.init()
        self.completer.delegate = self
        self.completer.resultTypes = [.address, .pointOfInterest, .query]
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.completions = Array(results.prefix(6))
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.completions = []
        }
    }

    func resolve(_ completion: MKLocalSearchCompletion) async -> ResolvedPlace? {
        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request(completion: completion)
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start(),
              let item = response.mapItems.first else {
            return nil
        }

        return ResolvedPlace(
            title: completion.title,
            subtitle: completion.subtitle,
            coordinate: item.placemark.coordinate
        )
    }

    func searchDirect(_ text: String) async -> ResolvedPlace? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Allow direct "lat, lon" input (e.g. "41.8902, 12.4922")
        let parts = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]),
           (-90...90).contains(lat), (-180...180).contains(lon) {
            return ResolvedPlace(
                title: String(format: "%.5f, %.5f", lat, lon),
                subtitle: "Coordinate manuali",
                coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
            )
        }

        isSearching = true
        defer { isSearching = false }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start(),
              let item = response.mapItems.first else {
            return nil
        }

        return ResolvedPlace(
            title: item.name ?? trimmed,
            subtitle: item.placemark.title ?? "",
            coordinate: item.placemark.coordinate
        )
    }
}
