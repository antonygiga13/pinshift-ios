import SwiftUI

@main
struct PinShiftApp: App {
    @StateObject private var bridge = LocationBridge()
    @StateObject private var favoritesStore = FavoritesStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bridge)
                .environmentObject(favoritesStore)
        }
    }
}
