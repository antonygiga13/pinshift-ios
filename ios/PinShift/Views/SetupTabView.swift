import SwiftUI
import UniformTypeIdentifiers

struct SetupTabView: View {
    @EnvironmentObject private var bridge: LocationBridge

    @State private var showFileImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Stato connessione") {
                    HStack {
                        Label("Stato", systemImage: bridge.connectionState.isConnected ? "checkmark.circle.fill" : "bolt.slash.circle")
                            .foregroundStyle(bridge.connectionState.isConnected ? .green : .secondary)
                        Spacer()
                        Text(bridge.connectionState.statusLabel)
                            .foregroundStyle(.secondary)
                    }

                    if let msg = bridge.lastMessage, !msg.isEmpty {
                        Text(msg)
                            .font(.caption)
                            .foregroundStyle(isErrorState ? .red : .secondary)
                    }

                    HStack(spacing: 12) {
                        Button {
                            Task {
                                _ = await bridge.connect()
                            }
                        } label: {
                            if bridge.isBusy {
                                ProgressView()
                            } else {
                                Text(bridge.connectionState.isConnected ? "Riconnetti" : "Testa Connessione")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bridge.isBusy || !bridge.hasPairingFile)

                        if bridge.connectionState.isConnected {
                            Button("Disconnetti", role: .destructive) {
                                bridge.disconnect()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }

                Section {
                    HStack {
                        Label(
                            bridge.hasPairingFile ? (bridge.pairingFileName ?? "pairing.plist") : "Nessun file importato",
                            systemImage: bridge.hasPairingFile ? "doc.badge.checkmark.fill" : "doc.badge.plus"
                        )
                        .foregroundStyle(bridge.hasPairingFile ? .green : .orange)
                        Spacer()
                    }

                    Button("Importa Pairing File (.rppairing / .plist)") {
                        importError = nil
                        showFileImporter = true
                    }

                    if bridge.hasPairingFile {
                        Button("Rimuovi Pairing File", role: .destructive) {
                            bridge.removePairingFile()
                        }
                    }

                    if let err = importError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("1. Pairing File")
                } footer: {
                    Text("Su iOS 26/27 genera un file 'Remote pairing' in idevice_pair (la prima scheda blu) e importalo qui. Su iOS 17–25 funziona anche il file Lockdown (.plist).")
                }

                Section {
                    HStack {
                        Text("IP Loopback")
                        Spacer()
                        TextField("10.7.0.1", text: $bridge.hostIP)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                            .frame(maxWidth: 160)
                    }

                    HStack {
                        Text("Porta Remote Pairing")
                        Spacer()
                        TextField(
                            bridge.discoveredPort.map { "Auto (\($0))" } ?? "Auto (Bonjour)",
                            text: $bridge.remotePairingPortText
                        )
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 160)
                    }
                } header: {
                    Text("2. Tunnel Locale (LocalDevVPN)")
                } footer: {
                    Text("Lascia la porta vuota per rilevarla automaticamente via Bonjour (_remotepairing._tcp). Assicurati che LocalDevVPN sia attiva e il Wi-Fi acceso.")
                }

                Section("Checklist rapida iPhone") {
                    checklistRow(
                        number: "1",
                        title: "Modalità Sviluppatore",
                        detail: "Settings → Privacy & Security → Developer Mode → On."
                    )
                    checklistRow(
                        number: "2",
                        title: "LocalDevVPN attiva",
                        detail: "Apri LocalDevVPN e premi Connect prima di usare PinShift."
                    )
                    checklistRow(
                        number: "3",
                        title: "Permesso Local Network",
                        detail: "Al primo Test di Connessione tocca Allow sul popup 'Local Network' di iOS."
                    )
                    checklistRow(
                        number: "4",
                        title: "Wi-Fi acceso",
                        detail: "Il servizio locale richiede il Wi-Fi attivo."
                    )
                }
            }
            .navigationTitle("Configurazione")
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.item, .data, .propertyList, .xml],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    do {
                        try bridge.importPairingFile(from: url)
                    } catch {
                        importError = "Impossibile leggere il file: \(error.localizedDescription)"
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
        }
    }

    private var isErrorState: Bool {
        if case .error = bridge.connectionState { return true }
        return false
    }

    private func checklistRow(number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(Color.blue, in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
