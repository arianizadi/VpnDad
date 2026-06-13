import Darwin
import Foundation
import Network
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let masterDNSHandshakeTimeout: TimeInterval = 25
    private let masterDNSHandshakePollIntervalNS: UInt64 = 250_000_000
    private let repository = ProfileRepository()
    private let engineRuntime = EngineRuntime()
    private let hevRunner = HevSocks5TunnelRunner()
    private let telemetry = TunnelTelemetry()
    private let telemetryQueue = DispatchQueue(label: "VpnDad.TunnelTelemetry")
    private let nativePacketStateLock = NSLock()
    private let nativePacketCountersLock = NSLock()
    private let nativePacketWriteQueue = DispatchQueue(label: "VpnDad.NativePacketOutput")
    // Each pending write block holds a packet copy; without a cap the serial
    // write queue can absorb an entire download burst and push the extension
    // past the jetsam footprint limit. Dropping IP packets is safe — TCP
    // retransmits and backs off, which is the backpressure we want.
    private let nativePacketMaxPendingWrites: Int64 = 512
    private var nativePacketPendingWrites: Int64 = 0
    private var telemetryTimer: DispatchSourceTimer?
    private var telemetryTick = 0
    private var nativePacketPumpActive = false
    private var nativePacketFlowWritePackets: UInt64 = 0
    private var nativePacketFlowWriteBytes: UInt64 = 0
    private var nativePacketFlowWriteFailures: UInt64 = 0
    private var nativePacketFlowDroppedPackets: UInt64 = 0
    private var nativePacketFlowInvalidOutputPackets: UInt64 = 0
    private var nativePacketLastFlowError: String?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Task { [self] in
            do {
                let resolvedProfile = try resolveProfile(options: options)
                let runtimeSelection = resolvedProfile.preparedForIOSTunnelStart()
                let profile = runtimeSelection.profile
                telemetry.start(
                    profile: profile,
                    socksAddress: AppConstants.defaultSocksAddress,
                    runtimeMode: runtimeSelection.runtimeMode,
                    runtimeModeSource: runtimeSelection.runtimeModeSource
                )
                startTelemetrySampler()
                resetNativePacketFlowCounters()
                telemetry.recordLifecycle("startTunnel invoked")
                log("starting tunnel for \(profile.name)")
                if profile.tunnelProtocol == .masterdns {
                    log(
                        "MasterDnsVPN runtime selected: \(runtimeSelection.runtimeMode.rawValue) " +
                        "source=\(runtimeSelection.runtimeModeSource)"
                    )
                }
                try await applyNetworkSettings(for: profile)
                log("network settings applied for \(profile.tunnelProtocol.rawValue)")
                telemetry.setPhase("engine starting")
                switch runtimeSelection.runtimeMode {
                case .hevSocks:
                    let profileJSON = try repository.profileJSONString(profile, includeSecrets: true)
                    try engineRuntime.start(
                        profileJSON: profileJSON,
                        socksAddress: AppConstants.defaultSocksAddress
                    ) { [weak self] line in
                        self?.log(line)
                    }
                    if profile.tunnelProtocol == .masterdns {
                        telemetry.setPhase("engine handshake")
                        try await waitForMasterDNSHandshake()
                    }
                    telemetry.setPhase("packet bridge starting")
                    try hevRunner.start(
                        socksAddress: AppConstants.defaultSocksAddress,
                        packetFlow: packetFlow
                    ) { [weak self] line in
                        self?.log(line)
                    } onExit: { [weak self] code in
                        self?.handlePacketBridgeExit(code)
                    }
                case .nativePacket:
                    let profileJSON = try repository.profileJSONString(profile, includeSecrets: true)
                    try engineRuntime.startPacket(
                        profileJSON: profileJSON,
                        packet: { [weak self] packet in
                            self?.writeNativePacket(packet)
                        }
                    ) { [weak self] line in
                        self?.log(line)
                    }
                    telemetry.setPhase("engine handshake")
                    try await waitForMasterDNSHandshake()
                    telemetry.setPhase("native packet bridge starting")
                    startNativePacketPump()
                }
                telemetry.markRunning()
                writeTelemetrySnapshot(forceLog: true)
                completionHandler(nil)
            } catch {
                telemetry.markFailed(error.localizedDescription)
                log("tunnel start failed: \(error.localizedDescription)")
                writeTelemetrySnapshot(forceLog: true)
                hevRunner.stop()
                stopNativePacketPump()
                engineRuntime.stop()
                completionHandler(error)
            }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let reasonName = providerStopReasonName(reason)
        telemetry.markStopping(reasonRaw: Int(reason.rawValue), reasonName: reasonName)
        log("stopping tunnel: reason=\(reason.rawValue) (\(reasonName))")
        writeTelemetrySnapshot(forceLog: true)
        stopNativePacketPump()
        hevRunner.stop()
        engineRuntime.stop()
        telemetry.markStopped()
        log("provider stop completed: reason=\(reason.rawValue) (\(reasonName))")
        writeTelemetrySnapshot(forceLog: true)
        stopTelemetrySampler()
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(engineRuntime.statusJSON().data(using: .utf8))
    }

    private func providerStopReasonName(_ reason: NEProviderStopReason) -> String {
        switch Int(reason.rawValue) {
        case 0:
            return "none"
        case 1:
            return "userInitiated"
        case 2:
            return "providerFailed"
        case 3:
            return "noNetworkAvailable"
        case 4:
            return "unrecoverableNetworkChange"
        case 5:
            return "providerDisabled"
        case 6:
            return "authenticationCanceled"
        case 7:
            return "configurationFailed"
        case 8:
            return "idleTimeout"
        case 9:
            return "configurationDisabled"
        case 10:
            return "configurationRemoved"
        case 11:
            return "superceded"
        case 12:
            return "userLogout"
        case 13:
            return "userSwitch"
        case 14:
            return "connectionFailed"
        case 15:
            return "sleep"
        case 16:
            return "appUpdate"
        case 17:
            return "internalError"
        default:
            return "unknown"
        }
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

    private func startNativePacketPump() {
        resetNativePacketFlowCounters()
        nativePacketStateLock.lock()
        nativePacketPumpActive = true
        nativePacketStateLock.unlock()
        readNativePackets()
        log("MasterDnsVPN native packet bridge started")
    }

    private func stopNativePacketPump() {
        nativePacketStateLock.lock()
        nativePacketPumpActive = false
        nativePacketStateLock.unlock()
    }

    private func isNativePacketPumpActive() -> Bool {
        nativePacketStateLock.lock()
        let active = nativePacketPumpActive
        nativePacketStateLock.unlock()
        return active
    }

    private func readNativePackets() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isNativePacketPumpActive() else {
                return
            }

            for packet in packets where !packet.isEmpty {
                do {
                    try self.engineRuntime.writePacket(packet)
                } catch {
                    self.handleNativePacketError(error)
                    return
                }
            }

            self.readNativePackets()
        }
    }

    private func writeNativePacket(_ packet: Data) {
        guard let protocolFamily = packetProtocolFamily(packet) else {
            recordNativePacketFlowInvalidOutput("native packet output was not IPv4 or IPv6")
            return
        }
        nativePacketCountersLock.lock()
        if nativePacketPendingWrites >= nativePacketMaxPendingWrites {
            nativePacketFlowDroppedPackets += 1
            nativePacketLastFlowError = "native packet output dropped: write queue full"
            nativePacketCountersLock.unlock()
            return
        }
        nativePacketPendingWrites += 1
        nativePacketCountersLock.unlock()
        nativePacketWriteQueue.async { [weak self] in
            guard let self else {
                return
            }
            self.nativePacketCountersLock.lock()
            self.nativePacketPendingWrites -= 1
            self.nativePacketCountersLock.unlock()
            guard self.isNativePacketPumpActive() else {
                return
            }
            let accepted = self.packetFlow.writePackets([packet], withProtocols: [protocolFamily])
            self.recordNativePacketFlowWrite(byteCount: packet.count, accepted: accepted)
        }
    }

    private func resetNativePacketFlowCounters() {
        nativePacketCountersLock.lock()
        nativePacketPendingWrites = 0
        nativePacketFlowWritePackets = 0
        nativePacketFlowWriteBytes = 0
        nativePacketFlowWriteFailures = 0
        nativePacketFlowDroppedPackets = 0
        nativePacketFlowInvalidOutputPackets = 0
        nativePacketLastFlowError = nil
        nativePacketCountersLock.unlock()
    }

    private func nativePacketFlowSnapshot() -> NativePacketFlowSnapshot {
        nativePacketCountersLock.lock()
        let snapshot = NativePacketFlowSnapshot(
            writePackets: nativePacketFlowWritePackets,
            writeBytes: nativePacketFlowWriteBytes,
            writeFailures: nativePacketFlowWriteFailures,
            droppedPackets: nativePacketFlowDroppedPackets,
            invalidOutputPackets: nativePacketFlowInvalidOutputPackets,
            lastError: nativePacketLastFlowError
        )
        nativePacketCountersLock.unlock()
        return snapshot
    }

    private func recordNativePacketFlowWrite(byteCount: Int, accepted: Bool) {
        nativePacketCountersLock.lock()
        if accepted {
            nativePacketFlowWritePackets += 1
            nativePacketFlowWriteBytes += UInt64(byteCount)
        } else {
            nativePacketFlowWriteFailures += 1
            nativePacketLastFlowError = "NEPacketTunnelFlow rejected native packet output"
        }
        nativePacketCountersLock.unlock()
    }

    private func recordNativePacketFlowInvalidOutput(_ error: String) {
        nativePacketCountersLock.lock()
        nativePacketFlowInvalidOutputPackets += 1
        nativePacketLastFlowError = error
        nativePacketCountersLock.unlock()
    }

    private func packetProtocolFamily(_ packet: Data) -> NSNumber? {
        guard let first = packet.first else {
            return nil
        }
        switch first >> 4 {
        case 4:
            return NSNumber(value: AF_INET)
        case 6:
            return NSNumber(value: AF_INET6)
        default:
            return nil
        }
    }

    private func handleNativePacketError(_ error: Error) {
        stopNativePacketPump()
        telemetry.markFailed(error.localizedDescription)
        log("native packet bridge failed: \(error.localizedDescription)")
        writeTelemetrySnapshot(forceLog: true)
        cancelTunnelWithError(error)
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

    @discardableResult
    private func writeTelemetrySnapshot(forceLog: Bool) -> TunnelMetrics {
        let metrics = telemetry.snapshot(
            hev: hevRunner.snapshot(),
            nativeFlow: nativePacketFlowSnapshot(),
            engineStatusJSON: engineRuntime.statusJSON(),
            resources: ProviderResourceSnapshot.current()
        )
        try? repository.writeTunnelMetrics(metrics)

        telemetryTick += 1
        guard forceLog || telemetryTick % 5 == 0 else {
            return metrics
        }
        log(
            "traffic(packet-flow): up=\(formatBytes(metrics.uploadBytes)) down=\(formatBytes(metrics.downloadBytes)) " +
            "rate=\(formatBytes(UInt64(max(metrics.totalBytesPerSecond, 0))))/s " +
            "packets=\(metrics.uploadPackets)up/\(metrics.downloadPackets)down " +
            "bridge=\(metrics.bridgeInputPackets)in/\(metrics.bridgeOutputPackets)out " +
            "arq-resends=\((metrics.arqDataResendsQueued ?? 0) + (metrics.arqControlResendsQueued ?? 0)) " +
            "arq-nacks=\(metrics.arqDataNackPacketsSent ?? 0)s/\(metrics.arqDataNackPacketsReceived ?? 0)r " +
            "fec-recovered=\(metrics.fecRecoveredPackets ?? 0) " +
            "configured-send=\(metrics.sendsPerPacket ?? 1)x " +
            "errors=r\(metrics.bridgeReadErrors)/w\(metrics.bridgeWriteErrors)/short\(metrics.bridgeShortWrites) " +
            "runtime=\(metrics.runtimeMode ?? "unknown") native=\(nativeSummary(metrics)) " +
            "provider=heartbeat resources=\(resourceSummary(metrics))"
        )
        return metrics
    }

    private func waitForMasterDNSHandshake() async throws {
        let deadline = Date().addingTimeInterval(masterDNSHandshakeTimeout)
        while Date() < deadline {
            let metrics = writeTelemetrySnapshot(forceLog: false)
            if metrics.sessionID != nil, (metrics.acceptedResolvers ?? 0) > 0 {
                log("MasterDnsVPN handshake verified: session=\(metrics.sessionID ?? 0), resolver=\(metrics.resolverAddress ?? "unknown")")
                return
            }
            if let failure = masterDNSStartupFailure(in: metrics) {
                throw TunnelRuntimeError.engineHandshakeFailed(failure)
            }
            try await Task.sleep(nanoseconds: masterDNSHandshakePollIntervalNS)
        }

        let metrics = writeTelemetrySnapshot(forceLog: true)
        let detail = metrics.lastError
            ?? metrics.engineLastError
            ?? metrics.lastLogLine
            ?? "session was not initialized within \(Int(masterDNSHandshakeTimeout)) seconds"
        throw TunnelRuntimeError.engineHandshakeFailed(detail)
    }

    private func handlePacketBridgeExit(_ code: Int32) {
        telemetry.markPacketBridgeExited(code: Int(code))
        let snapshot = telemetry.current()
        guard snapshot.status == "running" else {
            return
        }
        let error = TunnelRuntimeError.packetBridgeExited(code)
        telemetry.markFailed(error.localizedDescription)
        log("packet bridge exited while tunnel was running: code=\(code)")
        writeTelemetrySnapshot(forceLog: true)
        cancelTunnelWithError(error)
    }

    private func masterDNSStartupFailure(in metrics: TunnelMetrics) -> String? {
        if metrics.status == "failed" {
            return metrics.lastError ?? metrics.engineLastError ?? "engine reported failed status"
        }

        let candidates = [metrics.lastError, metrics.engineLastError, metrics.lastLogLine]
        for value in candidates.compactMap({ $0 }) {
            let lowercased = value.lowercased()
            if lowercased.contains("mtu tests failed")
                || lowercased.contains("no valid connections")
                || lowercased.contains("upload_mtu") {
                return value
            }
        }
        return nil
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private func resourceSummary(_ metrics: TunnelMetrics) -> String {
        [
            "rss=\(metrics.memoryResidentBytes.map(formatBytes) ?? "n/a")",
            "footprint=\(metrics.memoryPhysicalFootprintBytes.map(formatBytes) ?? "n/a")",
            "threads=\(metrics.threadCount.map(String.init) ?? "n/a")",
            "fds=\(metrics.openFileDescriptorCount.map(String.init) ?? "n/a")",
            "hev=\(metrics.hevRunning == true ? "running" : "not-running")"
        ].joined(separator: "/")
    }

    private func nativeSummary(_ metrics: TunnelMetrics) -> String {
        guard metrics.runtimeMode == MasterDNSRuntimeMode.nativePacket.rawValue else {
            return "n/a"
        }
        return [
            "tcp=\(metrics.nativeTCPFlowsActive ?? 0)/\(metrics.nativeTCPFlowsCreated ?? 0)",
            "tcpResets=\(metrics.nativeTCPEndpointResets ?? 0)",
            "dns=\(metrics.nativeDNSResponses ?? 0)/\(metrics.nativeDNSQueries ?? 0)",
            "udp=\(metrics.nativeUnsupportedUDP ?? 0)",
            "udpRejects=\(metrics.nativeUnsupportedUDPRejects ?? 0)",
            "udpPorts=\(metrics.nativeUnsupportedUDPTopPorts ?? "n/a")",
            "writes=\(metrics.nativePacketFlowWritePackets ?? 0)",
            "writeFailures=\((metrics.nativePacketWriteErrors ?? 0) + (metrics.nativePacketFlowWriteFailures ?? 0))",
            "writeDrops=\(metrics.nativePacketFlowDroppedPackets ?? 0)"
        ].joined(separator: "/")
    }

    private func excludedIPv4Routes(for profile: VPNProfile) -> [NEIPv4Route] {
        uniqueIPv4Routes(
            localIPv4ExclusionHosts() + resolverHosts(for: profile)
        )
    }

    private func excludedIPv6Routes(for profile: VPNProfile) -> [NEIPv6Route] {
        uniqueIPv6Routes(
            localIPv6ExclusionHosts() + resolverHosts(for: profile)
        )
    }

    private func localIPv4ExclusionHosts() -> [String] {
        [
            "10.0.0.0/8",
            "100.64.0.0/10",
            "169.254.0.0/16",
            "172.16.0.0/12",
            "192.168.0.0/16",
            "224.0.0.0/4"
        ]
    }

    private func localIPv6ExclusionHosts() -> [String] {
        [
            "fc00::/7",
            "fe80::/10",
            "ff00::/8"
        ]
    }

    private func uniqueIPv4Routes(_ hosts: [String]) -> [NEIPv4Route] {
        var seen = Set<String>()
        return hosts.compactMap { host in
            guard let route = ipv4Route(from: host), seen.insert(host).inserted else {
                return nil
            }
            return route
        }
    }

    private func uniqueIPv6Routes(_ hosts: [String]) -> [NEIPv6Route] {
        var seen = Set<String>()
        return hosts.compactMap { host in
            guard let route = ipv6Route(from: host), seen.insert(host).inserted else {
                return nil
            }
            return route
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

    private func ipv4Route(from host: String) -> NEIPv4Route? {
        let parts = host.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let prefixLength = Int(parts[1]), prefixLength >= 0, prefixLength <= 32 {
            let address = String(parts[0])
            guard IPv4Address(address) != nil else {
                return nil
            }
            return NEIPv4Route(destinationAddress: address, subnetMask: ipv4SubnetMask(prefixLength))
        }

        guard IPv4Address(host) != nil else {
            return nil
        }
        return NEIPv4Route(destinationAddress: host, subnetMask: "255.255.255.255")
    }

    private func ipv6Route(from host: String) -> NEIPv6Route? {
        let parts = host.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let prefixLength = Int(parts[1]), prefixLength >= 0, prefixLength <= 128 {
            let address = String(parts[0])
            guard IPv6Address(address) != nil else {
                return nil
            }
            return NEIPv6Route(destinationAddress: address, networkPrefixLength: NSNumber(value: prefixLength))
        }

        guard IPv6Address(host) != nil else {
            return nil
        }
        return NEIPv6Route(destinationAddress: host, networkPrefixLength: 128)
    }

    private func ipv4SubnetMask(_ prefixLength: Int) -> String {
        let clamped = max(0, min(prefixLength, 32))
        let mask = clamped == 0 ? UInt32(0) : UInt32.max << UInt32(32 - clamped)
        return [
            (mask >> 24) & 0xff,
            (mask >> 16) & 0xff,
            (mask >> 8) & 0xff,
            mask & 0xff
        ]
        .map { String($0) }
        .joined(separator: ".")
    }

    private func log(_ line: String) {
        telemetry.recordLogLine(line)
        NSLog("[VpnTunnelExtension] %@", line)
        try? repository.appendTunnelLog(line)
    }
}

private struct ProviderResourceSnapshot {
    var residentBytes: UInt64?
    var physicalFootprintBytes: UInt64?
    var threadCount: Int?
    var openFileDescriptorCount: Int?

    static func current() -> ProviderResourceSnapshot {
        ProviderResourceSnapshot(
            residentBytes: currentResidentBytes(),
            physicalFootprintBytes: currentPhysicalFootprintBytes(),
            threadCount: currentThreadCount(),
            openFileDescriptorCount: currentOpenFileDescriptorCount()
        )
    }

    private static func currentResidentBytes() -> UInt64? {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return UInt64(info.resident_size)
    }

    private static func currentPhysicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return UInt64(info.phys_footprint)
    }

    private static func currentThreadCount() -> Int? {
        var threadList: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        let result = task_threads(mach_task_self_, &threadList, &count)
        guard result == KERN_SUCCESS else {
            return nil
        }
        if let threadList {
            let byteCount = vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), byteCount)
        }
        return Int(count)
    }

    private static func currentOpenFileDescriptorCount() -> Int? {
        let limit = min(getdtablesize(), 4096)
        guard limit > 0 else {
            return nil
        }
        var count = 0
        for fd in 0..<limit where fcntl(fd, F_GETFD) != -1 {
            count += 1
        }
        return count
    }
}

private struct NativePacketFlowSnapshot {
    var writePackets: UInt64
    var writeBytes: UInt64
    var writeFailures: UInt64
    var droppedPackets: UInt64
    var invalidOutputPackets: UInt64
    var lastError: String?
}

private final class TunnelTelemetry {
    private let lock = NSLock()
    private var metrics = TunnelMetrics.empty
    private var lastSampleAt: Date?
    private var lastUploadBytes: UInt64 = 0
    private var lastDownloadBytes: UInt64 = 0

    func start(
        profile: VPNProfile,
        socksAddress: String,
        runtimeMode: MasterDNSRuntimeMode,
        runtimeModeSource: String
    ) {
        lock.lock()
        let now = Date()
        metrics = TunnelMetrics.empty
        metrics.status = "starting"
        metrics.phase = "profile resolved"
        metrics.profileName = profile.name
        metrics.tunnelProtocol = profile.tunnelProtocol.rawValue
        metrics.socksAddress = socksAddress
        metrics.runtimeMode = runtimeMode.rawValue
        metrics.runtimeModeSource = runtimeModeSource
        metrics.startedAt = now
        metrics.updatedAt = now
        metrics.providerStartedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerLastTelemetryWriteAt = now
        metrics.providerLastLifecycleEvent = "profile resolved"
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
        metrics.providerLastLifecycleEvent = phase
        lock.unlock()
    }

    func markRunning() {
        lock.lock()
        let now = Date()
        metrics.status = "running"
        metrics.phase = "running"
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerLastLifecycleEvent = "running"
        lock.unlock()
    }

    func markStopping(reasonRaw: Int, reasonName: String) {
        lock.lock()
        let now = Date()
        metrics.status = "stopping"
        metrics.phase = "stopping"
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerStoppingAt = now
        metrics.providerStopReasonRaw = reasonRaw
        metrics.providerStopReasonName = reasonName
        metrics.providerLastLifecycleEvent = "stopping: \(reasonName)"
        lock.unlock()
    }

    func markStopped() {
        lock.lock()
        let now = Date()
        metrics.status = "stopped"
        metrics.phase = "stopped"
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerStoppedAt = now
        metrics.providerLastLifecycleEvent = "stopped"
        lock.unlock()
    }

    func markFailed(_ error: String) {
        lock.lock()
        let now = Date()
        metrics.status = "failed"
        metrics.phase = "failed"
        metrics.lastError = error
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerLastLifecycleEvent = "failed: \(error)"
        lock.unlock()
    }

    func recordLifecycle(_ event: String) {
        lock.lock()
        let now = Date()
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerLastLifecycleEvent = event
        lock.unlock()
    }

    func markPacketBridgeExited(code: Int) {
        lock.lock()
        let now = Date()
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.packetBridgeExitedAt = now
        metrics.packetBridgeExitCode = code
        metrics.providerLastLifecycleEvent = "packet bridge exited: \(code)"
        lock.unlock()
    }

    func current() -> TunnelMetrics {
        lock.lock()
        let copy = metrics
        lock.unlock()
        return copy
    }

    func recordLogLine(_ line: String) {
        lock.lock()
        metrics.lastLogLine = line
        metrics.updatedAt = Date()

        let lowercased = line.lowercased()
        let isPacketFlowBackpressure = lowercased.contains("no buffer space available") ||
            lowercased.contains("packet-flow bridge backpressure")

        if !isPacketFlowBackpressure,
           line.contains("tunnel start failed") || line.contains("failed") {
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
        if line.contains("native packet bridge started") {
            metrics.phase = "native packet bridge running"
        }

        parseAcceptedResolver(line)
        parseDuplicateSendPolicy(line)
        parseSessionID(line)
        lock.unlock()
    }

    func snapshot(
        hev: HevRunnerSnapshot,
        nativeFlow: NativePacketFlowSnapshot,
        engineStatusJSON: String,
        resources: ProviderResourceSnapshot
    ) -> TunnelMetrics {
        lock.lock()
        let now = Date()
        metrics.updatedAt = now
        metrics.providerHeartbeatAt = now
        metrics.providerLastTelemetryWriteAt = now
        if let startedAt = metrics.startedAt {
            metrics.uptimeSeconds = max(0, Int(now.timeIntervalSince(startedAt)))
        }

        let nativeBridge = nativeBridgeSnapshot(engineStatusJSON)
        let bridgeInputPackets = nativeBridge?.inputPackets ?? hev.bridgeInputPackets
        let bridgeInputBytes = nativeBridge?.inputBytes ?? hev.bridgeInputBytes
        let bridgeOutputPackets = nativeBridge?.outputPackets ?? hev.bridgeOutputPackets
        let bridgeOutputBytes = nativeBridge?.outputBytes ?? hev.bridgeOutputBytes

        let uploadBytes = bridgeInputBytes
        let downloadBytes = bridgeOutputBytes
        metrics.uploadPackets = bridgeInputPackets
        metrics.downloadPackets = bridgeOutputPackets
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

        metrics.bridgeInputPackets = bridgeInputPackets
        metrics.bridgeInputBytes = bridgeInputBytes
        metrics.bridgeOutputPackets = bridgeOutputPackets
        metrics.bridgeOutputBytes = bridgeOutputBytes
        if metrics.firstBridgeInputAt == nil, bridgeInputPackets > 0 {
            metrics.firstBridgeInputAt = now
        }
        if metrics.firstBridgeOutputAt == nil, bridgeOutputPackets > 0 {
            metrics.firstBridgeOutputAt = now
        }
        metrics.bridgeReadErrors = hev.bridgeReadErrors
        metrics.bridgeWriteErrors = (nativeBridge?.packetWriteErrors ?? hev.bridgeWriteErrors) +
            nativeFlow.writeFailures +
            nativeFlow.invalidOutputPackets
        metrics.bridgeShortWrites = hev.bridgeShortWrites
        metrics.lastBridgeError = nativeBridge?.lastError ?? nativeFlow.lastError ?? hev.lastBridgeError
        metrics.nativePacketFlowWritePackets = nativeFlow.writePackets
        metrics.nativePacketFlowWriteBytes = nativeFlow.writeBytes
        metrics.nativePacketFlowWriteFailures = nativeFlow.writeFailures
        metrics.nativePacketFlowDroppedPackets = nativeFlow.droppedPackets
        metrics.nativePacketFlowInvalidOutputPackets = nativeFlow.invalidOutputPackets
        metrics.hevRunning = hev.isRunning
        metrics.hevExitCode = hev.exitCode.map(Int.init)
        metrics.hevExitedAt = hev.exitedAt
        metrics.memoryResidentBytes = resources.residentBytes
        metrics.memoryPhysicalFootprintBytes = resources.physicalFootprintBytes
        metrics.threadCount = resources.threadCount
        metrics.openFileDescriptorCount = resources.openFileDescriptorCount
        metrics.engineStatusJSON = engineStatusJSON
        applyEngineStatus(engineStatusJSON)

        let copy = metrics
        lock.unlock()
        return copy
    }

    private func nativeBridgeSnapshot(_ raw: String) -> (
        inputPackets: UInt64,
        inputBytes: UInt64,
        outputPackets: UInt64,
        outputBytes: UInt64,
        packetWriteErrors: UInt64,
        lastError: String?
    )? {
        guard
            let data = raw.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let native = object["nativePacket"] as? [String: Any]
        else {
            return nil
        }
        return (
            inputPackets: uint64Value(native["inputPackets"]) ?? 0,
            inputBytes: uint64Value(native["inputBytes"]) ?? 0,
            outputPackets: uint64Value(native["outputPackets"]) ?? 0,
            outputBytes: uint64Value(native["outputBytes"]) ?? 0,
            packetWriteErrors: uint64Value(native["packetWriteErrors"]) ?? 0,
            lastError: native["lastError"] as? String
        )
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
        if let native = object["nativePacket"] as? [String: Any] {
            metrics.nativeInputPackets = uint64Value(native["inputPackets"])
            metrics.nativeInputBytes = uint64Value(native["inputBytes"])
            metrics.nativeOutputPackets = uint64Value(native["outputPackets"])
            metrics.nativeOutputBytes = uint64Value(native["outputBytes"])
            metrics.nativePacketWriteErrors = uint64Value(native["packetWriteErrors"])
            metrics.nativeTCPFlowsActive = uint64Value(native["tcpFlowsActive"])
            metrics.nativeTCPFlowsCreated = uint64Value(native["tcpFlowsCreated"])
            metrics.nativeTCPFlowsClosed = uint64Value(native["tcpFlowsClosed"])
            metrics.nativeTCPEndpointErrors = uint64Value(native["tcpEndpointErrors"])
            metrics.nativeTCPEndpointResets = uint64Value(native["tcpEndpointResets"])
            metrics.nativeDNSQueries = uint64Value(native["dnsQueries"])
            metrics.nativeDNSCacheHits = uint64Value(native["dnsCacheHits"])
            metrics.nativeDNSPending = uint64Value(native["dnsPending"])
            metrics.nativeDNSResponses = uint64Value(native["dnsResponses"])
            metrics.nativeUnsupportedUDP = uint64Value(native["unsupportedUDP"])
            metrics.nativeUnsupportedUDPRejects = uint64Value(native["unsupportedUDPRejects"])
            metrics.nativeUnsupportedUDPTopPorts = native["unsupportedUDPTopPorts"] as? String
            metrics.nativeMalformedPackets = uint64Value(native["malformedPackets"])
            if let error = native["lastError"] as? String, !error.isEmpty {
                metrics.engineLastError = error
            }
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
