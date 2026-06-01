import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let repository = ProfileRepository()
    private let engineRuntime = EngineRuntime()
    private let hevRunner = HevSocks5TunnelRunner()
    private let telemetry = TunnelTelemetry()
    private let telemetryQueue = DispatchQueue(label: "VpnDad.TunnelTelemetry")
    private var telemetryTimer: DispatchSourceTimer?
    private var telemetryTick = 0

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task {
            do {
                let profile = try resolveProfile(options: options)
                telemetry.start(profile: profile, socksAddress: AppConstants.defaultSocksAddress)
                startTelemetrySampler()
                log("starting tunnel for \(profile.name)")
                try await applyNetworkSettings(for: profile)
                log("network settings applied for \(profile.tunnelProtocol.rawValue)")
                telemetry.setPhase("engine starting")
                let profileJSON = try repository.profileJSONString(profile)
                try engineRuntime.start(
                    profileJSON: profileJSON,
                    socksAddress: AppConstants.defaultSocksAddress
                ) { [weak self] line in
                    self?.log(line)
                }
                telemetry.setPhase("packet bridge starting")
                try hevRunner.start(
                    socksAddress: AppConstants.defaultSocksAddress,
                    packetFlow: packetFlow
                ) { [weak self] line in
                    self?.log(line)
                }
                telemetry.markRunning()
                writeTelemetrySnapshot(forceLog: true)
                completionHandler(nil)
            } catch {
                telemetry.markFailed(error.localizedDescription)
                log("tunnel start failed: \(error.localizedDescription)")
                writeTelemetrySnapshot(forceLog: true)
                hevRunner.stop()
                engineRuntime.stop()
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        telemetry.markStopping()
        log("stopping tunnel: reason=\(reason.rawValue)")
        writeTelemetrySnapshot(forceLog: true)
        hevRunner.stop()
        engineRuntime.stop()
        telemetry.markStopped()
        writeTelemetrySnapshot(forceLog: true)
        stopTelemetrySampler()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(engineRuntime.statusJSON().data(using: .utf8))
    }

    private func resolveProfile(options: [String: NSObject]?) throws -> VPNProfile {
        if let profileJSON = options?["profileJSON"] as? String {
            let profile = try JSONDecoder().decode(VPNProfile.self, from: Data(profileJSON.utf8))
            return try repository.resolved(profile)
        }

        let providerConfiguration = (protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration
        let rawID = (options?["profileID"] as? String)
            ?? (providerConfiguration?["profileID"] as? String)
        if let rawID, let id = UUID(uuidString: rawID) {
            return try repository.resolvedProfile(id: id)
        }

        if let id = try repository.readSelectedProfileID() {
            return try repository.resolvedProfile(id: id)
        }

        throw TunnelRuntimeError.missingProfile
    }

    private func applyNetworkSettings(for profile: VPNProfile) async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.254")

        let ipv4 = NEIPv4Settings(addresses: [AppConstants.tunnelIPv4Address], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        ipv4.excludedRoutes = excludedIPv4Routes(for: profile)
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: [AppConstants.tunnelIPv6Address],
            networkPrefixLengths: [NSNumber(value: 64)]
        )
        ipv6.includedRoutes = [NEIPv6Route.default()]
        ipv6.excludedRoutes = excludedIPv6Routes(for: profile)
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [AppConstants.fakeDNSAddress])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = NSNumber(value: 1280)

        log("applying network settings for \(profile.tunnelProtocol.rawValue)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            setTunnelNetworkSettings(settings) { error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func startTelemetrySampler() {
        stopTelemetrySampler()
        telemetryTick = 0
        let timer = DispatchSource.makeTimerSource(queue: telemetryQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.writeTelemetrySnapshot(forceLog: false)
        }
        timer.resume()
        telemetryTimer = timer
    }

    private func stopTelemetrySampler() {
        telemetryTimer?.cancel()
        telemetryTimer = nil
    }

    private func writeTelemetrySnapshot(forceLog: Bool) {
        let metrics = telemetry.snapshot(
            hev: hevRunner.snapshot(),
            engineStatusJSON: engineRuntime.statusJSON()
        )
        try? repository.writeTunnelMetrics(metrics)

        telemetryTick += 1
        guard forceLog || telemetryTick % 5 == 0 else {
            return
        }
        log(
            "traffic(packet-flow): up=\(formatBytes(metrics.uploadBytes)) down=\(formatBytes(metrics.downloadBytes)) " +
            "rate=\(formatBytes(UInt64(max(metrics.totalBytesPerSecond, 0))))/s " +
            "packets=\(metrics.uploadPackets)up/\(metrics.downloadPackets)down " +
            "bridge=\(metrics.bridgeInputPackets)in/\(metrics.bridgeOutputPackets)out " +
            "arq-resends=\((metrics.arqDataResendsQueued ?? 0) + (metrics.arqControlResendsQueued ?? 0)) " +
            "arq-nacks=\(metrics.arqDataNackPacketsSent ?? 0)s/\(metrics.arqDataNackPacketsReceived ?? 0)r " +
            "fec-recovered=\(metrics.fecRecoveredPackets ?? 0) " +
            "configured-send=\(metrics.sendsPerPacket ?? 1)x errors=r\(metrics.bridgeReadErrors)/w\(metrics.bridgeWriteErrors)/short\(metrics.bridgeShortWrites)"
        )
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private func excludedIPv4Routes(for profile: VPNProfile) -> [NEIPv4Route] {
        resolverHosts(for: profile).compactMap { host in
            guard IPv4Address(host) != nil else {
                return nil
            }
            return NEIPv4Route(destinationAddress: host, subnetMask: "255.255.255.255")
        }
    }

    private func excludedIPv6Routes(for profile: VPNProfile) -> [NEIPv6Route] {
        resolverHosts(for: profile).compactMap { host in
            guard IPv6Address(host) != nil else {
                return nil
            }
            return NEIPv6Route(destinationAddress: host, networkPrefixLength: 128)
        }
    }

    private func resolverHosts(for profile: VPNProfile) -> [String] {
        var seen = Set<String>()
        return profile.resolvers.compactMap { resolver in
            let host = resolverHost(from: resolver.address)
            guard !host.isEmpty, seen.insert(host).inserted else {
                return nil
            }
            return host
        }
    }

    private func resolverHost(from address: String) -> String {
        let value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("["),
           let end = value.firstIndex(of: "]") {
            return String(value[value.index(after: value.startIndex)..<end])
        }
        if value.filter({ $0 == ":" }).count == 1,
           let separator = value.lastIndex(of: ":") {
            return String(value[..<separator])
        }
        return value
    }

    private func log(_ line: String) {
        telemetry.recordLogLine(line)
        NSLog("[VpnTunnelExtension] %@", line)
        try? repository.appendTunnelLog(line)
    }
}

private final class TunnelTelemetry {
    private let lock = NSLock()
    private var metrics = TunnelMetrics.empty
    private var lastSampleAt: Date?
    private var lastUploadBytes: UInt64 = 0
    private var lastDownloadBytes: UInt64 = 0

    func start(profile: VPNProfile, socksAddress: String) {
        lock.lock()
        let now = Date()
        metrics = TunnelMetrics.empty
        metrics.status = "starting"
        metrics.phase = "profile resolved"
        metrics.profileName = profile.name
        metrics.tunnelProtocol = profile.tunnelProtocol.rawValue
        metrics.socksAddress = socksAddress
        metrics.startedAt = now
        metrics.updatedAt = now
        metrics.uptimeSeconds = 0
        if let resolver = profile.resolvers.first {
            metrics.resolverAddress = resolver.address
        }
        lastSampleAt = nil
        lastUploadBytes = 0
        lastDownloadBytes = 0
        lock.unlock()
    }

    func setPhase(_ phase: String) {
        lock.lock()
        metrics.phase = phase
        metrics.updatedAt = Date()
        lock.unlock()
    }

    func markRunning() {
        lock.lock()
        metrics.status = "running"
        metrics.phase = "running"
        metrics.updatedAt = Date()
        lock.unlock()
    }

    func markStopping() {
        lock.lock()
        metrics.status = "stopping"
        metrics.phase = "stopping"
        metrics.updatedAt = Date()
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        metrics.status = "stopped"
        metrics.phase = "stopped"
        metrics.updatedAt = Date()
        lock.unlock()
    }

    func markFailed(_ error: String) {
        lock.lock()
        metrics.status = "failed"
        metrics.phase = "failed"
        metrics.lastError = error
        metrics.updatedAt = Date()
        lock.unlock()
    }

    func recordLogLine(_ line: String) {
        lock.lock()
        metrics.lastLogLine = line
        metrics.updatedAt = Date()

        if line.contains("tunnel start failed") || line.contains("failed") {
            metrics.lastError = line
        }
        if line.contains("starting MasterDnsVPN") || line.contains("starting VayDNS") {
            metrics.phase = "engine starting"
        }
        if line.contains("engine started") {
            metrics.phase = "engine running"
        }
        if line.contains("HevSocks5Tunnel packet-flow bridge created") {
            metrics.phase = "packet bridge ready"
        }
        if line.contains("HevSocks5Tunnel started") {
            metrics.phase = "packet bridge running"
        }

        parseAcceptedResolver(line)
        parseDuplicateSendPolicy(line)
        parseSessionID(line)
        lock.unlock()
    }

    func snapshot(hev: HevRunnerSnapshot, engineStatusJSON: String) -> TunnelMetrics {
        lock.lock()
        let now = Date()
        metrics.updatedAt = now
        if let startedAt = metrics.startedAt {
            metrics.uptimeSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        }

        let uploadBytes = hev.bridgeInputBytes
        let downloadBytes = hev.bridgeOutputBytes
        metrics.uploadPackets = hev.bridgeInputPackets
        metrics.downloadPackets = hev.bridgeOutputPackets
        metrics.uploadBytes = uploadBytes
        metrics.downloadBytes = downloadBytes
        metrics.totalBytes = uploadBytes + downloadBytes

        if let lastSampleAt {
            let interval = max(now.timeIntervalSince(lastSampleAt), 0.001)
            metrics.uploadBytesPerSecond = Double(uploadBytes.subtractingFloor(lastUploadBytes)) / interval
            metrics.downloadBytesPerSecond = Double(downloadBytes.subtractingFloor(lastDownloadBytes)) / interval
            metrics.totalBytesPerSecond = metrics.uploadBytesPerSecond + metrics.downloadBytesPerSecond
        }
        lastSampleAt = now
        lastUploadBytes = uploadBytes
        lastDownloadBytes = downloadBytes

        metrics.bridgeInputPackets = hev.bridgeInputPackets
        metrics.bridgeInputBytes = hev.bridgeInputBytes
        metrics.bridgeOutputPackets = hev.bridgeOutputPackets
        metrics.bridgeOutputBytes = hev.bridgeOutputBytes
        if metrics.firstBridgeInputAt == nil, hev.bridgeInputPackets > 0 {
            metrics.firstBridgeInputAt = now
        }
        if metrics.firstBridgeOutputAt == nil, hev.bridgeOutputPackets > 0 {
            metrics.firstBridgeOutputAt = now
        }
        metrics.bridgeReadErrors = hev.bridgeReadErrors
        metrics.bridgeWriteErrors = hev.bridgeWriteErrors
        metrics.bridgeShortWrites = hev.bridgeShortWrites
        metrics.lastBridgeError = hev.lastBridgeError
        metrics.engineStatusJSON = engineStatusJSON
        applyEngineStatus(engineStatusJSON)

        let copy = metrics
        lock.unlock()
        return copy
    }

    private func parseAcceptedResolver(_ line: String) {
        guard line.contains("Accepted") else {
            return
        }
        if let viaRange = line.range(of: " via ") {
            let tail = line[viaRange.upperBound...]
            metrics.resolverAddress = String(tail.split(separator: "|", maxSplits: 1)[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        metrics.uploadMTU = intValue(after: "upload=", in: line) ?? metrics.uploadMTU
        metrics.downloadMTU = intValue(after: "download=", in: line) ?? metrics.downloadMTU
        metrics.acceptedResolvers = intValue(after: "valid=", in: line) ?? metrics.acceptedResolvers
        metrics.rejectedResolvers = intValue(after: "rejected=", in: line) ?? metrics.rejectedResolvers
    }

    private func parseDuplicateSendPolicy(_ line: String) {
        guard let sends = intValue(after: "Each packet will be sent ", in: line) else {
            return
        }
        metrics.sendsPerPacket = sends
        metrics.duplicateCopiesPerPacket = max(0, sends - 1)
    }

    private func parseSessionID(_ line: String) {
        if let id = intValue(after: "Session Initialized Successfully (ID: ", in: line) {
            metrics.sessionID = id
        }
    }

    private func applyEngineStatus(_ raw: String) {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }
        metrics.engineRunning = object["running"] as? Bool
        metrics.engineStartedAt = object["startedAt"] as? String
        if let error = object["lastError"] as? String, !error.isEmpty {
            metrics.engineLastError = error
        }
        guard let arq = object["arq"] as? [String: Any] else {
            return
        }
        metrics.arqStreamsCreated = uint64Value(arq["streamsCreated"])
        metrics.arqStreamsClosed = uint64Value(arq["streamsClosed"])
        metrics.arqStreamsActive = uint64Value(arq["streamsActive"])
        metrics.arqDataPacketsRead = uint64Value(arq["dataPacketsRead"])
        metrics.arqDataPacketsQueued = uint64Value(arq["dataPacketsQueued"])
        metrics.arqDataPacketsQueueRejected = uint64Value(arq["dataPacketsQueueRejected"])
        metrics.arqDataPacketsDequeued = uint64Value(arq["dataPacketsDequeued"])
        metrics.arqDataPacketsAcked = uint64Value(arq["dataPacketsAcked"])
        metrics.arqDataPacketsReceived = uint64Value(arq["dataPacketsReceived"])
        metrics.arqDataAckPacketsSent = uint64Value(arq["dataAckPacketsSent"])
        metrics.arqDataAckPacketsRejected = uint64Value(arq["dataAckPacketsRejected"])
        metrics.arqDataNackPacketsSent = uint64Value(arq["dataNackPacketsSent"])
        metrics.arqDataNackPacketsRejected = uint64Value(arq["dataNackPacketsRejected"])
        metrics.arqDataNackPacketsReceived = uint64Value(arq["dataNackPacketsReceived"])
        metrics.arqDataResendsQueued = uint64Value(arq["dataResendsQueued"])
        metrics.arqDataResendsRejected = uint64Value(arq["dataResendsRejected"])
        metrics.arqDataNackResendsQueued = uint64Value(arq["dataNackResendsQueued"])
        metrics.arqDataNackResendsRejected = uint64Value(arq["dataNackResendsRejected"])
        metrics.arqDataTimeoutResendsQueued = uint64Value(arq["dataTimeoutResendsQueued"])
        metrics.arqDataTimeoutResendsRejected = uint64Value(arq["dataTimeoutResendsRejected"])
        metrics.arqDataMaxRetriesExceeded = uint64Value(arq["dataMaxRetriesExceeded"])
        metrics.arqDataTTLExpired = uint64Value(arq["dataTTLExpired"])
        metrics.arqControlPacketsQueued = uint64Value(arq["controlPacketsQueued"])
        metrics.arqControlPacketsQueueRejected = uint64Value(arq["controlPacketsQueueRejected"])
        metrics.arqControlPacketsDequeued = uint64Value(arq["controlPacketsDequeued"])
        metrics.arqControlPacketsAcked = uint64Value(arq["controlPacketsAcked"])
        metrics.arqControlResendsQueued = uint64Value(arq["controlResendsQueued"])
        metrics.arqControlResendsRejected = uint64Value(arq["controlResendsRejected"])
        metrics.arqControlMaxRetriesExceeded = uint64Value(arq["controlMaxRetriesExceeded"])
        metrics.arqControlTTLExpired = uint64Value(arq["controlTTLExpired"])

        guard let fec = object["fec"] as? [String: Any] else {
            return
        }
        metrics.fecNegotiated = uint64Value(fec["negotiated"])
        metrics.fecGroupsCreated = uint64Value(fec["groupsCreated"])
        metrics.fecSymbolsSent = uint64Value(fec["symbolsSent"])
        metrics.fecSymbolsReceived = uint64Value(fec["symbolsReceived"])
        metrics.fecDecodedGroups = uint64Value(fec["decodedGroups"])
        metrics.fecRecoveredPackets = uint64Value(fec["recoveredPackets"])
        metrics.fecFailedGroups = uint64Value(fec["failedGroups"])
        metrics.fecOverheadBytes = uint64Value(fec["overheadBytes"])
    }

    private func intValue(after marker: String, in line: String) -> Int? {
        guard let range = line.range(of: marker) else {
            return nil
        }
        let tail = line[range.upperBound...]
        let digits = tail.prefix { $0.isNumber }
        return Int(digits)
    }

    private func uint64Value(_ raw: Any?) -> UInt64? {
        switch raw {
        case let value as UInt64:
            return value
        case let value as Int:
            return value >= 0 ? UInt64(value) : nil
        case let value as NSNumber:
            return value.int64Value >= 0 ? value.uint64Value : nil
        case let value as String:
            return UInt64(value)
        default:
            return nil
        }
    }
}

private extension UInt64 {
    func subtractingFloor(_ value: UInt64) -> UInt64 {
        self > value ? self - value : 0
    }
}
