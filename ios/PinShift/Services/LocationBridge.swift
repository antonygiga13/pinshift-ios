import CoreLocation
import Foundation
import LocBridge
import SwiftUI

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected(String)
    case error(String)

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var isConnecting: Bool {
        if case .connecting = self { return true }
        return false
    }

    var statusLabel: String {
        switch self {
        case .disconnected:
            return "Disconnesso"
        case .connecting:
            return "Connessione..."
        case .connected:
            return "Connesso"
        case .error:
            return "Errore"
        }
    }
}

/// Discovers the local `_remotepairing._tcp` port via Bonjour and triggers
/// the iOS Local Network permission dialog on first run.
@MainActor
private final class RemotePairingDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolvingServices: [NetService] = []
    private var continuation: CheckedContinuation<UInt16?, Never>?
    private var timeoutTask: Task<Void, Never>?

    func discoverPort(timeoutSeconds: Double = 3.0) async -> UInt16? {
        await withCheckedContinuation { cont in
            self.continuation = cont
            self.browser.delegate = self
            self.browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")

            self.timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.finish(with: nil)
            }
        }
    }

    private func finish(with port: UInt16?) {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser.stop()
        resolvingServices.forEach { $0.stop() }
        resolvingServices.removeAll()
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: port)
        }
    }

    nonisolated func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        Task { @MainActor in
            self.resolvingServices.append(service)
            service.delegate = self
            service.resolve(withTimeout: 2.5)
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let port = sender.port
        Task { @MainActor in
            if port > 0 && port <= Int(UInt16.max) {
                self.finish(with: UInt16(port))
            }
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in
            self.finish(with: nil)
        }
    }
}

@MainActor
final class LocationBridge: ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected
    @Published var activeCoordinate: CLLocationCoordinate2D?
    @Published var activeLabel: String?
    @Published var lastMessage: String?
    @Published var isBusy: Bool = false

    @Published var hostIP: String {
        didSet {
            UserDefaults.standard.set(hostIP, forKey: Self.hostIPKey)
        }
    }

    /// Optional manual port override for Remote Pairing (empty = Auto via Bonjour / 49152+).
    @Published var remotePairingPortText: String {
        didSet {
            UserDefaults.standard.set(remotePairingPortText, forKey: Self.rpPortKey)
        }
    }

    @Published private(set) var discoveredPort: UInt16?
    @Published private(set) var hasPairingFile: Bool = false
    @Published private(set) var pairingFileName: String?

    private static let hostIPKey = "pinshift.hostIP"
    private static let rpPortKey = "pinshift.rpPort"
    private static let pairingNameKey = "pinshift.pairingFileName"

    init() {
        self.hostIP = UserDefaults.standard.string(forKey: Self.hostIPKey) ?? "10.7.0.1"
        self.remotePairingPortText = UserDefaults.standard.string(forKey: Self.rpPortKey) ?? ""
        self.pairingFileName = UserDefaults.standard.string(forKey: Self.pairingNameKey)
        refreshPairingFileStatus()
    }

    // MARK: - Pairing file storage

    private var pairingFileURL: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pairing.plist")
    }

    /// Also checks Documents/ so users can drop a pairing file via Files app or idevice_pair AFC.
    private func findBundledDocumentsPairingFile() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first,
              let contents = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) else {
            return nil
        }
        return contents.first { url in
            let ext = url.pathExtension.lowercased()
            return ext == "rppairing" || ext == "plist" || ext == "mobiledevicepairing"
        }
    }

    func refreshPairingFileStatus() {
        let fm = FileManager.default
        if fm.fileExists(atPath: pairingFileURL.path) {
            hasPairingFile = true
            if pairingFileName == nil {
                pairingFileName = "pairing.plist"
            }
            return
        }

        if let docURL = findBundledDocumentsPairingFile(),
           let data = try? Data(contentsOf: docURL) {
            try? data.write(to: pairingFileURL, options: .atomic)
            hasPairingFile = true
            pairingFileName = docURL.lastPathComponent
            UserDefaults.standard.set(docURL.lastPathComponent, forKey: Self.pairingNameKey)
            return
        }

        hasPairingFile = false
        pairingFileName = nil
    }

    func importPairingFile(from url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw NSError(
                domain: "PinShift",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Il file selezionato è vuoto."]
            )
        }

        try data.write(to: pairingFileURL, options: .atomic)
        hasPairingFile = true
        pairingFileName = url.lastPathComponent
        UserDefaults.standard.set(url.lastPathComponent, forKey: Self.pairingNameKey)
        lastMessage = "Pairing file importato: \(url.lastPathComponent)"
    }

    func removePairingFile() {
        try? FileManager.default.removeItem(at: pairingFileURL)
        hasPairingFile = false
        pairingFileName = nil
        UserDefaults.standard.removeObject(forKey: Self.pairingNameKey)
        disconnect()
    }

    private func loadPairingBytes() -> Data? {
        refreshPairingFileStatus()
        return try? Data(contentsOf: pairingFileURL)
    }

    // MARK: - Bonjour discovery & Native Rust bridge calls

    func discoverRemotePairingPort() async -> UInt16? {
        let discovery = RemotePairingDiscovery()
        let port = await discovery.discoverPort(timeoutSeconds: 2.5)
        self.discoveredPort = port
        return port
    }

    func connect() async -> Bool {
        guard let pairingData = loadPairingBytes() else {
            connectionState = .error("Importa prima il pairing file nella scheda Configurazione.")
            return false
        }

        let targetHost = hostIP.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetHost.isEmpty else {
            connectionState = .error("Inserisci un indirizzo IP valido (es. 10.7.0.1).")
            return false
        }

        isBusy = true
        connectionState = .connecting
        defer { isBusy = false }

        // Resolve Remote Pairing port (manual override -> Bonjour discovery -> 0 auto-probe)
        let manualPort = UInt16(remotePairingPortText.trimmingCharacters(in: .whitespacesAndNewlines))
        let resolvedPort: UInt16
        if let manualPort, manualPort > 0 {
            resolvedPort = manualPort
        } else if let bonjourPort = await discoverRemotePairingPort() {
            resolvedPort = bonjourPort
        } else {
            resolvedPort = 0
        }

        let result: (Int32, String) = await Task.detached(priority: .userInitiated) {
            let res = targetHost.withCString { cHost in
                pairingData.withUnsafeBytes { rawBuf -> LocBridgeResult in
                    let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress
                    return locbridge_connect(cHost, resolvedPort, ptr, pairingData.count)
                }
            }
            defer { locbridge_free_string(res.message) }
            let msg = res.message.map { String(cString: $0) } ?? ""
            return (res.code, msg)
        }.value

        if result.0 == 0 {
            connectionState = .connected(result.1)
            lastMessage = result.1
            return true
        } else {
            connectionState = .error(result.1)
            lastMessage = result.1
            return false
        }
    }

    func setLocation(_ coordinate: CLLocationCoordinate2D, label: String? = nil) async {
        if locbridge_is_connected() == 0 {
            let ok = await connect()
            guard ok else { return }
        }

        isBusy = true
        defer { isBusy = false }

        let lat = coordinate.latitude
        let lon = coordinate.longitude

        let result: (Int32, String) = await Task.detached(priority: .userInitiated) {
            let res = locbridge_set_location(lat, lon)
            defer { locbridge_free_string(res.message) }
            let msg = res.message.map { String(cString: $0) } ?? ""
            return (res.code, msg)
        }.value

        if result.0 == 0 {
            activeCoordinate = coordinate
            activeLabel = label
            lastMessage = result.1
            if !connectionState.isConnected {
                connectionState = .connected("Connesso")
            }
        } else {
            connectionState = .error(result.1)
            lastMessage = result.1
        }
    }

    func clearLocation() async {
        isBusy = true
        defer { isBusy = false }

        if locbridge_is_connected() == 0 {
            activeCoordinate = nil
            activeLabel = nil
            lastMessage = "GPS reale ripristinato"
            return
        }

        let result: (Int32, String) = await Task.detached(priority: .userInitiated) {
            let res = locbridge_clear_location()
            defer { locbridge_free_string(res.message) }
            let msg = res.message.map { String(cString: $0) } ?? ""
            return (res.code, msg)
        }.value

        if result.0 == 0 {
            activeCoordinate = nil
            activeLabel = nil
            lastMessage = result.1
        } else {
            connectionState = .error(result.1)
            lastMessage = result.1
        }
    }

    func disconnect() {
        Task.detached(priority: .userInitiated) {
            let res = locbridge_disconnect()
            locbridge_free_string(res.message)
        }
        connectionState = .disconnected
        activeCoordinate = nil
        activeLabel = nil
    }
}
