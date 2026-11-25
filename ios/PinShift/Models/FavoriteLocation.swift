import CoreLocation
import Foundation

struct FavoriteLocation: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var subtitle: String
    var latitude: Double
    var longitude: Double

    init(
        id: UUID = UUID(),
        name: String,
        subtitle: String = "",
        latitude: Double,
        longitude: Double
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var formattedCoordinates: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    static let presets: [FavoriteLocation] = [
        FavoriteLocation(name: "Roma — Colosseo", subtitle: "Italia", latitude: 41.89021, longitude: 12.49223),
        FavoriteLocation(name: "Milano — Duomo", subtitle: "Italia", latitude: 45.46421, longitude: 9.19000),
        FavoriteLocation(name: "Londra — Big Ben", subtitle: "Regno Unito", latitude: 51.50073, longitude: -0.12463),
        FavoriteLocation(name: "New York — Times Square", subtitle: "Stati Uniti", latitude: 40.75800, longitude: -73.98550),
        FavoriteLocation(name: "Tokyo — Shibuya", subtitle: "Giappone", latitude: 35.65952, longitude: 139.70055),
    ]
}

@MainActor
final class FavoritesStore: ObservableObject {
    @Published var favorites: [FavoriteLocation] = []

    private let storageKey = "pinshift.favorites.v1"

    init() {
        load()
    }

    func add(name: String, subtitle: String = "", coordinate: CLLocationCoordinate2D) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? String(format: "Pin %.4f, %.4f", coordinate.latitude, coordinate.longitude) : trimmed
        let item = FavoriteLocation(
            name: title,
            subtitle: subtitle,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude
        )
        favorites.insert(item, at: 0)
        save()
    }

    func remove(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        save()
    }

    func remove(_ item: FavoriteLocation) {
        favorites.removeAll { $0.id == item.id }
        save()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([FavoriteLocation].self, from: data) else {
            favorites = []
            return
        }
        favorites = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
