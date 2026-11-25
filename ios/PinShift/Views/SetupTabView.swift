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

                    Button("Importa Pairing File (.plist / .mobiledevicepairing)") {
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
                    Text("Genera il file di pairing una sola volta dal PC Windows con idevice_pair (modalità standard/Lockdown) e importalo qui, oppure copialo nella cartella PinShift dell'app File.")
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
                } header: {
                    Text("2. Tunnel Locale (LocalDevVPN)")
                } footer: {
                    Text("Prima di cambiare posizione, attiva l'app gratuita LocalDevVPN dall'App Store (IP predefinito: 10.7.0.1) e tieni il Wi-Fi acceso.")
                }

                Section("Checklist rapida iPhone") {
                    checklistRow(
                        number: "1",
                        title: "Modalità Sviluppatore",
                        detail: "Impostazioni → Privacy e sicurezza → Modalità sviluppatore → Attiva."
                    )
                    checklistRow(
                        number: "2",
                        title: "LocalDevVPN attiva",
                        detail: "Scarica LocalDevVPN dall'App Store e premi Connect prima di usare PinShift."
                    )
                    checklistRow(
                        number: "3",
                        title: "Wi-Fi acceso",
                        detail: "Su iOS 17+ il servizio locale richiede il Wi-Fi attivo (anche senza internet)."
                    )
                    checklistRow(
                        number: "4",
                        title: "Developer Disk Image (DDI)",
                        detail: "Se la connessione DVT fallisce, collega l'iPhone al PC una volta dopo un riavvio o usa StikDebug/SideStore per montare la DDI."
                    )
                }
            }
            .navigationTitle("Configurazione")
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, .propertyList, .xml, .item],
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
