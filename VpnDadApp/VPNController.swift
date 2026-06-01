import Foundation
import NetworkExtension

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid

    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var lastLoggedStatusRawValue: Int?

    init() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let connection = notification.object as? NEVPNConnection else { return }
            Task { @MainActor in
                self?.setStatus(connection.status, source: "notification")
            }
        }
    }

    deinit {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    func refresh() async {
        do {
            manager = try await loadOrCreateManager()
            setStatus(manager?.connection.status ?? .invalid, source: "refresh")
        } catch {
            setStatus(.invalid, source: "refresh error")
        }
    }

    func connect(profile: VPNProfile) async throws {
        let repository = ProfileRepository()
        try? repository.appendTunnelLog("app connect requested for \(profile.name)")
        let profileJSON = try repository.profileJSONForTunnel(id: profile.id)
        try repository.writeSelectedProfileID(profile.id)
        try? repository.appendTunnelLog("app selected profile \(profile.id.uuidString)")

        let activeManager = try await loadOrCreateManager()
        let tunnelProtocol = NETunnelProviderProtocol()
        tunnelProtocol.providerBundleIdentifier = AppConstants.tunnelBundleIdentifier
        tunnelProtocol.providerConfiguration = ["profileID": profile.id.uuidString]
        tunnelProtocol.serverAddress = profile.name
        tunnelProtocol.disconnectOnSleep = false

        activeManager.localizedDescription = "VpnDad"
        activeManager.protocolConfiguration = tunnelProtocol
        activeManager.isEnabled = true

        try await save(activeManager)
        try await load(activeManager)
        manager = activeManager
        try? repository.appendTunnelLog("app starting VPN tunnel using \(AppConstants.tunnelBundleIdentifier)")
        try activeManager.connection.startVPNTunnel(options: [
            "profileID": profile.id.uuidString as NSString,
            "profileJSON": profileJSON as NSString
        ])
        status = activeManager.connection.status
        try? repository.appendTunnelLog("app startVPNTunnel accepted; waiting for iOS status update")
    }

    func disconnect() {
        try? ProfileRepository().appendTunnelLog("app disconnect requested")
        manager?.connection.stopVPNTunnel()
        setStatus(manager?.connection.status ?? .invalid, source: "disconnect request")
    }

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers = try await loadAllManagers()
        if let existing = managers.first(where: { manager in
            if manager.localizedDescription == "VpnDad" {
                return true
            }
            let tunnelProtocol = manager.protocolConfiguration as? NETunnelProviderProtocol
            return tunnelProtocol?.providerBundleIdentifier == AppConstants.tunnelBundleIdentifier
        }) {
            return existing
        }
        return NETunnelProviderManager()
    }

    private func loadAllManagers() async throws -> [NETunnelProviderManager] {
        try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: managers ?? [])
            }
        }
    }

    private func save(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func load(_ manager: NETunnelProviderManager) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func setStatus(_ newStatus: NEVPNStatus, source: String) {
        status = newStatus
        guard lastLoggedStatusRawValue != newStatus.rawValue else {
            return
        }
        lastLoggedStatusRawValue = newStatus.rawValue
        try? ProfileRepository().appendTunnelLog("app VPN status changed to \(newStatus.displayName) via \(source)")
    }
}

extension NEVPNStatus {
    var displayName: String {
        switch self {
        case .invalid:
            return "Invalid"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        case .reasserting:
            return "Reconnecting"
        case .disconnecting:
            return "Disconnecting"
        @unknown default:
            return "Unknown"
        }
    }
}
