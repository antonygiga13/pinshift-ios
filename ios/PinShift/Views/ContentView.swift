import CoreLocation
import SwiftUI

enum AppTab: Hashable {
    case map
    case favorites
    case setup
}

struct ContentView: View {
    @EnvironmentObject private var bridge: LocationBridge
    @State private var selectedTab: AppTab = .map
    @State private var selectedCoordinate: CLLocationCoordinate2D = CLLocationCoordinate2D(
        latitude: 41.89021,
        longitude: 12.49223
    )
    @State private var selectedTitle: String = "Roma — Colosseo"
    @State private var selectedSubtitle: String = "Tocca la mappa o cerca un indirizzo"
    @State private var mapFocusTrigger: UUID = UUID()

    var body: some View {
        TabView(selection: $selectedTab) {
            MapTabView(
                selectedCoordinate: $selectedCoordinate,
                selectedTitle: $selectedTitle,
                selectedSubtitle: $selectedSubtitle,
                mapFocusTrigger: mapFocusTrigger,
                onOpenSetup: { selectedTab = .setup }
            )
            .tabItem {
                Label("Mappa", systemImage: "map.fill")
            }
            .tag(AppTab.map)

            FavoritesTabView { favorite, applyImmediately in
                selectedCoordinate = favorite.coordinate
                selectedTitle = favorite.name
                selectedSubtitle = favorite.subtitle.isEmpty ? favorite.formattedCoordinates : favorite.subtitle
                mapFocusTrigger = UUID()
                selectedTab = .map

                if applyImmediately {
                    Task {
                        await bridge.setLocation(favorite.coordinate, label: favorite.name)
                    }
                }
            }
            .tabItem {
                Label("Preferiti", systemImage: "star.fill")
            }
            .tag(AppTab.favorites)

            SetupTabView()
                .tabItem {
                    Label("Configura", systemImage: "gearshape.fill")
                }
                .badge(bridge.hasPairingFile ? nil : "!")
                .tag(AppTab.setup)
        }
    }
}
