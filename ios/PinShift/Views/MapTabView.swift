import CoreLocation
import MapKit
import SwiftUI

struct MapTabView: View {
    @EnvironmentObject private var bridge: LocationBridge
    @EnvironmentObject private var favoritesStore: FavoritesStore
    @StateObject private var searchService = PlaceSearchService()

    @Binding var selectedCoordinate: CLLocationCoordinate2D
    @Binding var selectedTitle: String
    @Binding var selectedSubtitle: String
    let mapFocusTrigger: UUID
    let onOpenSetup: () -> Void

    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 41.89021, longitude: 12.49223),
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        )
    )
    @State private var showSaveFavoriteAlert = false
    @State private var favoriteNameDraft = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            MapReader { proxy in
                Map(position: $cameraPosition) {
                    Marker(selectedTitle, systemImage: "mappin.circle.fill", coordinate: selectedCoordinate)
                        .tint(.blue)

                    if let active = bridge.activeCoordinate {
                        Annotation("GPS Simulato", coordinate: active) {
                            ZStack {
                                Circle()
                                    .fill(Color.green.opacity(0.22))
                                    .frame(width: 44, height: 44)
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 16, height: 16)
                                    .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            }
                        }
                    }
                }
                .mapStyle(.standard(elevation: .realistic))
                .mapControls {
                    MapCompass()
                    MapScaleView()
                }
                .onTapGesture { screenPoint in
                    isSearchFocused = false
                    if let coord = proxy.convert(screenPoint, from: .local) {
                        selectedCoordinate = coord
                        selectedTitle = "Punto selezionato"
                        selectedSubtitle = String(format: "%.5f, %.5f", coord.latitude, coord.longitude)
                    }
                }
            }
            .ignoresSafeArea(edges: .top)

            VStack(spacing: 10) {
                searchHeader
                statusPill

                if !searchService.completions.isEmpty && isSearchFocused {
                    completionsList
                }

                Spacer()

                bottomControlCard
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .onChange(of: mapFocusTrigger) { _, _ in
            focusCamera(on: selectedCoordinate)
        }
        .alert("Salva nei preferiti", isPresented: $showSaveFavoriteAlert) {
            TextField("Nome (es. Ufficio, Casa, Parigi)", text: $favoriteNameDraft)
            Button("Annulla", role: .cancel) {}
            Button("Salva") {
                favoritesStore.add(
                    name: favoriteNameDraft,
                    subtitle: selectedSubtitle,
                    coordinate: selectedCoordinate
                )
            }
        } message: {
            Text(String(format: "Coordinate: %.5f, %.5f", selectedCoordinate.latitude, selectedCoordinate.longitude))
        }
    }

    private var searchHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Cerca città, indirizzo o lat, lon...", text: $searchService.query)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .focused($isSearchFocused)
                .onSubmit {
                    Task {
                        if let place = await searchService.searchDirect(searchService.query) {
                            applySearchResult(place)
                        }
                    }
                }

            if searchService.isSearching {
                ProgressView()
                    .scaleEffect(0.85)
            } else if !searchService.query.isEmpty {
                Button {
                    searchService.query = ""
                    searchService.completions = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }

    private var statusPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Text(statusText)
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 4)

            if !bridge.hasPairingFile {
                Button("Configura") {
                    onOpenSetup()
                }
                .font(.caption.weight(.bold))
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    private var completionsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(searchService.completions, id: \.self) { completion in
                    Button {
                        Task {
                            if let place = await searchService.resolve(completion) {
                                applySearchResult(place)
                            }
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(completion.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            if !completion.subtitle.isEmpty {
                                Text(completion.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                    Divider().padding(.leading, 14)
                }
            }
        }
        .frame(maxHeight: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
    }

    private var bottomControlCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(String(format: "%.5f, %.5f", selectedCoordinate.latitude, selectedCoordinate.longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    favoriteNameDraft = selectedTitle == "Punto selezionato" ? "" : selectedTitle
                    showSaveFavoriteAlert = true
                } label: {
                    Image(systemName: "star.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                }
                .accessibilityLabel("Salva nei preferiti")
            }

            if case .error(let errMsg) = bridge.connectionState {
                Text(errMsg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            HStack(spacing: 10) {
                Button {
                    Task {
                        await bridge.setLocation(selectedCoordinate, label: selectedTitle)
                    }
                } label: {
                    HStack {
                        if bridge.isBusy {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.85)
                        } else {
                            Image(systemName: "location.fill")
                        }
                        Text(bridge.activeCoordinate == nil ? "Imposta Posizione" : "Sposta Qui")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isBusy)

                if bridge.activeCoordinate != nil {
                    Button(role: .destructive) {
                        Task {
                            await bridge.clearLocation()
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle.fill")
                            .font(.title3)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.bordered)
                    .disabled(bridge.isBusy)
                    .accessibilityLabel("Ripristina GPS reale")
                }
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }

    private var statusColor: Color {
        if bridge.activeCoordinate != nil {
            return .green
        }
        switch bridge.connectionState {
        case .connected:
            return .blue
        case .connecting:
            return .orange
        case .error:
            return .red
        case .disconnected:
            return .gray
        }
    }

    private var statusText: String {
        if let active = bridge.activeCoordinate {
            let label = bridge.activeLabel ?? String(format: "%.4f, %.4f", active.latitude, active.longitude)
            return "GPS simulato: \(label)"
        }
        if !bridge.hasPairingFile {
            return "Pairing file mancante — apri Configura"
        }
        return bridge.connectionState.statusLabel
    }

    private func applySearchResult(_ place: ResolvedPlace) {
        isSearchFocused = false
        searchService.query = place.title
        searchService.completions = []
        selectedCoordinate = place.coordinate
        selectedTitle = place.title
        selectedSubtitle = place.subtitle
        focusCamera(on: place.coordinate)
    }

    private func focusCamera(on coordinate: CLLocationCoordinate2D) {
        withAnimation(.easeInOut(duration: 0.45)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.03, longitudeDelta: 0.03)
                )
            )
        }
    }
}
