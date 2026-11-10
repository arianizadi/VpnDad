import Foundation
import NetworkExtension
import UIKit

@MainActor
final class VPNController: ObservableObject {
    @Published private(set) var status: NEVPNStatus = .invalid
    /// Profile the current (or most recent) tunnel was started with.
    @Published private(set) var activeProfileID: UUID?
    /// When the current connect attempt began; drives the progress UI.
    @Published private(set) var connectStartedAt: Date?

    private let repository = ProfileRepository()
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

    var isTunnelActive: Bool {
        status == .connected || status == .connecting || status == .reasserting
    }

    func isActive(_ profile: VPNProfile) -> Bool {
        isTunnelActive && activeProfileID == profile.id
    }

    /// The tunnel status as it applies to `profile`: a tunnel running for a
    /// different profile reads as disconnected here.
    func status(for profile: VPNProfile) -> NEVPNStatus {
        guard status != .invalid, status != .disconnected else {
            return status
        }
        return activeProfileID == nil || activeProfileID == profile.id ? status : .disconnected
    }

    func refresh() async {
        #if targetEnvironment(simulator)
        // The simulator cannot run a packet tunnel. Launching with
        // VPNDAD_DEMO_STATUS=connecting|connected shows those UI states there.
        if let demo = ProcessInfo.processInfo.environment["VPNDAD_DEMO_STATUS"] {
            activeProfileID = try? repository.readSelectedProfileID()
            connectStartedAt = demo == "connecting" ? Date() : nil
            status = demo == "connecting" ? .connecting : (demo == "connected" ? .connected : .disconnected)
            return
        }
        #endif
        do {
            let loaded = try await loadOrCreateManager()
            manager = loaded
            activeProfileID = profileID(from: loaded) ?? (try? repository.readSelectedProfileID())
            setStatus(loaded.connection.status, source: "refresh")
        } catch {
            setStatus(.invalid, source: "refresh error")
        }
    }

    func connect(profile: VPNProfile) async throws {
        try? repository.appendTunnelLog("app connect requested for \(profile.name)")
        let startSelection = try repository.resolvedProfile(id: profile.id).preparedForIOSTunnelStart()
        let profileJSON = try repository.profileJSONString(startSelection.profile, includeSecrets: true)

        let activeManager = try await loadOrCreateManager()
        manager = activeManager

        // startVPNTunnel is ignored while a tunnel is up, so switching
        // profiles has to bring the old one down first.
        if activeManager.connection.status != .disconnected, activeManager.connection.status != .invalid {
            try? repository.appendTunnelLog("app stopping the active tunnel before switching profile")
            activeManager.connection.stopVPNTunnel()
            await waitForDisconnect(activeManager)
        }

        try repository.writeSelectedProfileID(profile.id)
        try? repository.appendTunnelLog("app selected profile \(profile.id.uuidString)")
        try? repository.appendTunnelLog(
            "app selected runtime \(startSelection.runtimeMode.rawValue) source=\(startSelection.runtimeModeSource)"
        )

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
        try? repository.appendTunnelLog("app starting VPN tunnel using \(AppConstants.tunnelBundleIdentifier)")
        activeProfileID = profile.id
        connectStartedAt = Date()
        do {
            try activeManager.connection.startVPNTunnel(options: [
                "profileID": profile.id.uuidString as NSString,
                "profileJSON": profileJSON as NSString
            ])
        } catch {
            connectStartedAt = nil
            throw error
        }
        setStatus(activeManager.connection.status, source: "start request")
        try? repository.appendTunnelLog("app startVPNTunnel accepted; waiting for iOS status update")
    }

    func disconnect() {
        try? repository.appendTunnelLog("app disconnect requested")
        guard let manager else {
            // The manager has not been loaded yet (very early tap): load it,
            // then stop, rather than silently doing nothing.
            Task {
                await refresh()
                self.manager?.connection.stopVPNTunnel()
            }
            return
        }
        manager.connection.stopVPNTunnel()
        setStatus(manager.connection.status, source: "disconnect request")
    }

    private func waitForDisconnect(_ manager: NETunnelProviderManager) async {
        for _ in 0..<50 {
            let current = manager.connection.status
            if current == .disconnected || current == .invalid {
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func profileID(from manager: NETunnelProviderManager) -> UUID? {
        let configuration = (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        return (configuration?["profileID"] as? String).flatMap(UUID.init(uuidString:))
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
        let previous = status
        if previous != newStatus {
            status = newStatus
            // One haptic per transition, here rather than in the views, since
            // several screens observe the same status.
            if newStatus == .connected {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } else if newStatus == .disconnected, previous == .connecting,
                      (try? repository.readTunnelMetrics())?.status == "failed" {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
        if newStatus == .connected || newStatus == .disconnected || newStatus == .invalid {
            connectStartedAt = nil
        }
        guard lastLoggedStatusRawValue != newStatus.rawValue else {
            return
        }
        lastLoggedStatusRawValue = newStatus.rawValue
        try? repository.appendTunnelLog("app VPN status changed to \(newStatus.displayName) via \(source)")
        if newStatus == .disconnecting || newStatus == .disconnected {
            appendDisconnectMetricsSnapshot(newStatus)
        }
    }

    private func appendDisconnectMetricsSnapshot(_ status: NEVPNStatus) {
        guard let metrics = try? repository.readTunnelMetrics() else {
            return
        }
        let metricsAge = max(0, Date().timeIntervalSince(metrics.updatedAt))
        // Metrics older than this belong to a previous tunnel session; logging
        // them as if they describe the current disconnect produces misleading
        // failure entries in the health timeline.
        guard metricsAge <= 120 else {
            try? repository.appendTunnelLog(
                "app observed \(status.displayName); last extension metrics are " +
                "\(formatSeconds(metricsAge)) old (previous session), not attributing them to this disconnect"
            )
            return
        }
        let bridgeErrors = metrics.bridgeReadErrors + metrics.bridgeWriteErrors + metrics.bridgeShortWrites
        let engineState = metrics.engineRunning.map { $0 ? "running" : "not running" } ?? "unknown"
        let heartbeatAge = metrics.providerHeartbeatAt.map { max(0, Date().timeIntervalSince($0)) }
        let providerState: String
        if let reason = metrics.providerStopReasonName {
            providerState = "stop=\(reason)/\(metrics.providerStopReasonRaw.map(String.init) ?? "n/a")"
        } else if metrics.status == "running", metrics.engineRunning == true, metricsAge >= 3 {
            // The provider was running and never executed stopTunnel: the
            // process was killed externally, most commonly by the jetsam
            // memory limit (~50 MB footprint for tunnel extensions).
            providerState = "stale-running-no-stop-reason (extension killed by iOS, likely memory limit)"
        } else {
            providerState = metrics.providerLastLifecycleEvent ?? "unknown"
        }
        let hevState: String
        if let exitCode = metrics.hevExitCode {
            hevState = "exit=\(exitCode)"
        } else {
            hevState = metrics.hevRunning == true ? "running" : "not-running"
        }
        let resourceState = [
            metrics.memoryResidentBytes.map { "rss=\($0)B" },
            metrics.memoryPhysicalFootprintBytes.map { "footprint=\($0)B" },
            metrics.threadCount.map { "threads=\($0)" },
            metrics.openFileDescriptorCount.map { "fds=\($0)" }
        ].compactMap { $0 }.joined(separator: " ")
        let nativeState = [
            metrics.nativeTCPFlowsActive.map { "tcpActive=\($0)" },
            metrics.nativeTCPFlowsCreated.map { "tcpCreated=\($0)" },
            metrics.nativeTCPFlowsClosed.map { "tcpClosed=\($0)" },
            metrics.nativeUnsupportedUDP.map { "unsupportedUDP=\($0)" },
            metrics.nativeUnsupportedUDPRejects.map { "udpRejects=\($0)" },
            metrics.nativePacketWriteErrors.map { "engineWriteErrors=\($0)" },
            metrics.nativePacketFlowWriteFailures.map { "flowWriteFailures=\($0)" },
            metrics.nativePacketFlowInvalidOutputPackets.map { "invalidOutput=\($0)" }
        ].compactMap { $0 }.joined(separator: " ")
        try? repository.appendTunnelLog(
            "app observed \(status.displayName) with last metrics " +
            "status=\(metrics.status) phase=\(metrics.phase) engine=\(engineState) " +
            "runtime=\(metrics.runtimeMode ?? "unknown") source=\(metrics.runtimeModeSource ?? "unknown") " +
            "age=\(formatSeconds(metricsAge)) heartbeat=\(heartbeatAge.map(formatSeconds) ?? "n/a") " +
            "provider=\(providerState) hev=\(hevState) " +
            "uptime=\(metrics.uptimeSeconds)s total=\(metrics.totalBytes)B " +
            "packets=\(metrics.uploadPackets)up/\(metrics.downloadPackets)down " +
            "bridgeErrors=\(bridgeErrors) configured-send=\(metrics.sendsPerPacket ?? 1)x " +
            "arqQueueRejects=\(arqQueueRejects(metrics)) arqAckSuppressions=\(metrics.arqDataAckPacketsRejected ?? 0) " +
            "native=\(nativeState.isEmpty ? "n/a" : nativeState) " +
            "resources=\(resourceState.isEmpty ? "n/a" : resourceState)"
        )
    }

    private func arqQueueRejects(_ metrics: TunnelMetrics) -> UInt64 {
        [
            metrics.arqDataPacketsQueueRejected,
            metrics.arqDataResendsRejected,
            metrics.arqDataNackPacketsRejected,
            metrics.arqControlPacketsQueueRejected,
            metrics.arqControlResendsRejected
        ].compactMap { $0 }.reduce(0, +)
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        if seconds < 10 {
            return String(format: "%.1fs", seconds)
        }
        return "\(Int(seconds.rounded()))s"
    }
}

extension NEVPNStatus {
    var displayName: String {
        switch self {
        case .invalid:
            return L10n.string("Invalid")
        case .disconnected:
            return L10n.string("Disconnected")
        case .connecting:
            return L10n.string("Connecting")
        case .connected:
            return L10n.string("Connected")
        case .reasserting:
            return L10n.string("Reconnecting")
        case .disconnecting:
            return L10n.string("Disconnecting")
        @unknown default:
            return L10n.string("Unknown")
        }
    }
}
