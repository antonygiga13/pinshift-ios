import CoreLocation
import SwiftUI

struct FavoritesTabView: View {
    @EnvironmentObject private var favoritesStore: FavoritesStore
    let onSelectFavorite: (_ favorite: FavoriteLocation, _ applyImmediately: Bool) -> Void

    @State private var showManualSheet = false
    @State private var manualName = ""
    @State private var manualLat = ""
    @State private var manualLon = ""
    @State private var manualError: String?

    var body: some View {
        NavigationStack {
            List {
                Section("I tuoi preferiti") {
                    if favoritesStore.favorites.isEmpty {
                        Text("Nessun preferito salvato. Tocca la stella sulla mappa o usa il pulsante + in alto.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favoritesStore.favorites) { fav in
                            favoriteRow(fav)
                        }
                        .onDelete(perform: favoritesStore.remove)
                    }
                }

                Section("Città rapide") {
                    ForEach(FavoriteLocation.presets) { preset in
                        favoriteRow(preset)
                    }
                }
            }
            .navigationTitle("Preferiti")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manualName = ""
                        manualLat = ""
                        manualLon = ""
                        manualError = nil
                        showManualSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showManualSheet) {
                NavigationStack {
                    Form {
                        Section("Nuova posizione manuale") {
                            TextField("Nome (es. Casa)", text: $manualName)
                            TextField("Latitudine (es. 45.4642)", text: $manualLat)
                                .keyboardType(.numbersAndPunctuation)
                            TextField("Longitudine (es. 9.1900)", text: $manualLon)
                                .keyboardType(.numbersAndPunctuation)
                        }

                        if let err = manualError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                    .navigationTitle("Aggiungi coordinate")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Annulla") { showManualSheet = false }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Salva") {
                                saveManualFavorite()
                            }
                        }
                    }
                }
            }
        }
    }

    private func favoriteRow(_ item: FavoriteLocation) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body.weight(.medium))
                Text(item.subtitle.isEmpty ? item.formattedCoordinates : "\(item.subtitle) • \(item.formattedCoordinates)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Vai") {
                onSelectFavorite(item, true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectFavorite(item, false)
        }
    }

    private func saveManualFavorite() {
        let latText = manualLat.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        let lonText = manualLon.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)

        guard let lat = Double(latText), let lon = Double(lonText),
              (-90...90).contains(lat), (-180...180).contains(lon) else {
            manualError = "Inserisci latitudine (-90..90) e longitudine (-180..180) valide."
            return
        }

        favoritesStore.add(
            name: manualName,
            subtitle: "Coordinate manuali",
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)
        )
        showManualSheet = false
    }
}
