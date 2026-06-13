import Combine
import Darwin
import Foundation
import Network
import NetworkExtension

enum TunnelHealthVerdict: String, Codable, Equatable {
    case disconnected
    case starting
    case working
    case degraded
    case reconnectNeeded
    case broken
    case waitingForTraffic

    var displayName: String {
        switch self {
        case .disconnected:
            return L10n.string("Disconnected")
        case .starting:
            return L10n.string("Starting")
        case .working:
            return L10n.string("Working")
        case .degraded:
            return L10n.string("Degraded")
        case .reconnectNeeded:
            return L10n.string("Reconnect Needed")
        case .broken:
            return L10n.string("Broken")
        case .waitingForTraffic:
            return L10n.string("Waiting for Traffic")
        }
    }

    var systemImage: String {
        switch self {
        case .disconnected:
            return "power"
        case .starting:
            return "hourglass"
        case .working:
            return "checkmark.shield"
        case .degraded:
            return "exclamationmark.triangle"
        case .reconnectNeeded:
            return "arrow.triangle.2.circlepath"
        case .broken:
            return "xmark.octagon"
        case .waitingForTraffic:
            return "clock.arrow.circlepath"
        }
    }
}

enum HealthTimelineSeverity: String, Codable {
    case info
    case success
    case warning
    case failure
}

struct HealthTimelineEvent: Identifiable, Equatable {
    let id = UUID()
    var date: Date?
    var title: String
    var detail: String
    var severity: HealthTimelineSeverity
}

struct TunnelHealthReport: Equatable {
    var verdict: TunnelHealthVerdict
    var summary: String
    var evidence: [String]
    var timeline: [HealthTimelineEvent]
}

enum TunnelHealthEvaluator {
    static func evaluate(
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        probe: HealthProbeSnapshot?,
        tunnelLog: String
    ) -> TunnelHealthReport {
        let currentProbe = probe?.profileID == profile.id ? probe : nil
        let timeline = timelineEvents(from: tunnelLog, metrics: metrics, probe: currentProbe)

        switch vpnStatus {
        case .invalid, .disconnected:
            return TunnelHealthReport(
                verdict: .disconnected,
                summary: L10n.string("VPN is not connected."),
                evidence: disconnectedEvidence(vpnStatus: vpnStatus, metrics: metrics),
                timeline: timeline
            )
        case .connecting, .reasserting, .disconnecting:
            return TunnelHealthReport(
                verdict: .starting,
                summary: L10n.string("VPN is changing state."),
                evidence: [L10n.string("iOS status is %@.", vpnStatus.displayName)],
                timeline: timeline
            )
        case .connected:
            break
        @unknown default:
            return TunnelHealthReport(
                verdict: .starting,
                summary: L10n.string("iOS returned an unknown VPN status."),
                evidence: [L10n.string("iOS status is %@.", "\(vpnStatus.rawValue)")],
                timeline: timeline
            )
        }

        guard let metrics else {
            return TunnelHealthReport(
                verdict: .waitingForTraffic,
                summary: L10n.string("Connected, waiting for tunnel metrics."),
                evidence: [L10n.string("No extension metrics have been written yet.")],
                timeline: timeline
            )
        }

        var evidence: [String] = []
        let metricsAge = Date().timeIntervalSince(metrics.updatedAt)
        let bridgeErrors = metrics.bridgeReadErrors + metrics.bridgeWriteErrors + metrics.bridgeShortWrites
        let trafficSeen = metrics.totalBytes > 0 || metrics.bridgeInputPackets > 0 || metrics.bridgeOutputPackets > 0
        let arqResends = (metrics.arqDataResendsQueued ?? 0) + (metrics.arqControlResendsQueued ?? 0)
        let arqQueued = (metrics.arqDataPacketsQueued ?? 0) +
            (metrics.arqDataResendsQueued ?? 0) +
            (metrics.arqControlPacketsQueued ?? 0) +
            (metrics.arqControlResendsQueued ?? 0)
        let arqResendRatio = arqQueued > 0 ? Double(arqResends) / Double(arqQueued) : 0
        let arqExpiry = (metrics.arqDataMaxRetriesExceeded ?? 0) +
            (metrics.arqDataTTLExpired ?? 0) +
            (metrics.arqControlMaxRetriesExceeded ?? 0) +
            (metrics.arqControlTTLExpired ?? 0)
        let arqQueueRejects = totalARQQueueRejects(metrics)
        let arqAckRejects = metrics.arqDataAckPacketsRejected ?? 0
        let arqQueueRejectRatio = arqQueued > 0 ? Double(arqQueueRejects) / Double(arqQueued) : 0

        if metrics.status == "failed" {
            return reconnectNeeded(L10n.string("Reconnect needed: tunnel startup failed."), evidence: compact([
                metrics.lastError,
                metrics.engineLastError,
                metrics.lastLogLine
            ]), timeline: timeline)
        }

        if metrics.engineRunning == false {
            return reconnectNeeded(L10n.string("Reconnect needed: iOS is connected, but the engine is not running."), evidence: compact([
                metrics.engineLastError,
                metrics.lastError,
                metrics.lastLogLine
            ]), timeline: timeline)
        }

        if currentProbe?.tunnelHandshake.status == .failed {
            return reconnectNeeded(
                L10n.string("Reconnect needed: tunnel handshake check failed."),
                evidence: [currentProbe?.tunnelHandshake.detail ?? L10n.string("No handshake detail was available.")],
                timeline: timeline
            )
        }

        if currentProbe?.expectedExitIPMatched == false {
            return reconnectNeeded(
                L10n.string("Reconnect needed: connected through the wrong exit IP."),
                evidence: [
                    L10n.string("Expected %@.", currentProbe?.expectedExitIP ?? L10n.string("n/a")),
                    L10n.string("Observed %@.", currentProbe?.observedExitIP ?? L10n.string("n/a"))
                ],
                timeline: timeline
            )
        }

        if arqExpiry > 0 {
            return reconnectNeeded(
                L10n.string("Reconnect needed: ARQ packets expired or exceeded retry limits."),
                evidence: [L10n.string("ARQ expiry count: %@.", "\(arqExpiry)")],
                timeline: timeline
            )
        }

        if arqQueueRejects > 50 && arqQueueRejectRatio >= 0.25 {
            return reconnectNeeded(
                L10n.string("Reconnect needed: ARQ rejects spiked."),
                evidence: [L10n.string("ARQ rejects: %@, reject ratio: %@.", "\(arqQueueRejects)", formatPercent(arqQueueRejectRatio))],
                timeline: timeline
            )
        }

        if let currentProbe, allCriticalProbeChecksFailed(currentProbe), metrics.uptimeSeconds >= 5 {
            return reconnectNeeded(
                L10n.string("Reconnect needed: connected, but all critical probes failed."),
                evidence: [
                    L10n.string("Public IP: %@", currentProbe.publicIP.detail),
                    L10n.string("1.1.1.1/help: %@", currentProbe.directHTTPS.detail),
                    L10n.string("Resolver: %@", currentProbe.resolverReachability.detail),
                    L10n.string("Handshake: %@", currentProbe.tunnelHandshake.detail)
                ],
                timeline: timeline
            )
        }

        if !trafficSeen,
           metrics.uptimeSeconds >= 15,
           let currentProbe,
           anyCriticalProbeCheckFailed(currentProbe) {
            return reconnectNeeded(
                L10n.string("Reconnect needed: no bridge packets are moving."),
                evidence: [
                    L10n.string("Uptime is %@.", L10n.string("%ds", metrics.uptimeSeconds)),
                    L10n.string("Bridge packets are %@ in / %@ out.", "\(metrics.bridgeInputPackets)", "\(metrics.bridgeOutputPackets)")
                ],
                timeline: timeline
            )
        }

        if metricsAge > 20 {
            evidence.append(L10n.string("Metrics are %@ old.", L10n.string("%ds", Int(metricsAge))))
        }
        if bridgeErrors > 0 {
            evidence.append(L10n.string("Bridge errors: read %@, write %@, short %@.", "\(metrics.bridgeReadErrors)", "\(metrics.bridgeWriteErrors)", "\(metrics.bridgeShortWrites)"))
        }
        if arqResends > 10 && arqResendRatio >= 0.15 {
            evidence.append(L10n.string("ARQ resend ratio is %@ across %@ resends.", formatPercent(arqResendRatio), "\(arqResends)"))
        }
        if arqQueueRejects > 0 {
            evidence.append(L10n.string("ARQ rejects: %@.", "\(arqQueueRejects)"))
        }
        if arqAckRejects > 0 {
            evidence.append(L10n.string("ARQ ACK rejects: %@.", "\(arqAckRejects)"))
        }
        if let currentProbe, anyProbeCheckFailed(currentProbe) {
            evidence.append(L10n.string("One or more health probes failed."))
        }
        if let currentProbe, currentProbe.dnsLeak.status == .warning {
            evidence.append(currentProbe.dnsLeak.detail)
        }
        if !trafficSeen, metrics.uptimeSeconds >= 15 {
            evidence.append(L10n.string("No bridge packets have moved after %@.", L10n.string("%ds", metrics.uptimeSeconds)))
        }

        if !evidence.isEmpty {
            return TunnelHealthReport(
                verdict: .degraded,
                summary: L10n.string("Tunnel is connected, but health signals are degraded."),
                evidence: evidence,
                timeline: timeline
            )
        }

        if let currentProbe, anyProbeCheckPassed(currentProbe) {
            var workingEvidence = [L10n.string("At least one health probe passed.")]
            if let observedIP = currentProbe.observedExitIP {
                workingEvidence.append(L10n.string("Observed public IP: %@.", observedIP))
            }
            if currentProbe.expectedExitIPMatched == true {
                workingEvidence.append(L10n.string("Expected exit IP matched."))
            }
            if !currentProbe.reportedDNSServers.isEmpty {
                workingEvidence.append(L10n.string("DNS resolvers reported: %@.", currentProbe.reportedDNSServers.joined(separator: ", ")))
            }
            return TunnelHealthReport(
                verdict: .working,
                summary: L10n.string("VPN is connected and health checks are passing."),
                evidence: workingEvidence,
                timeline: timeline
            )
        }

        if trafficSeen {
            return TunnelHealthReport(
                verdict: .waitingForTraffic,
                summary: L10n.string("Traffic is moving; run checks to verify exit IP."),
                evidence: [L10n.string("Transferred %@.", ByteCountFormatter.string(fromByteCount: Int64(metrics.totalBytes), countStyle: .binary))],
                timeline: timeline
            )
        }

        return TunnelHealthReport(
            verdict: .waitingForTraffic,
            summary: L10n.string("Connected, waiting for traffic or health checks."),
            evidence: [L10n.string("Engine phase: %@.", metrics.phase)],
            timeline: timeline
        )
    }

    private static func reconnectNeeded(_ summary: String, evidence: [String], timeline: [HealthTimelineEvent]) -> TunnelHealthReport {
        TunnelHealthReport(
            verdict: .reconnectNeeded,
            summary: summary,
            evidence: evidence.isEmpty ? [L10n.string("No extra error detail was available.")] : evidence,
            timeline: timeline
        )
    }

    private static func compact(_ values: [String?]) -> [String] {
        values.compactMap { value in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            return value
        }
    }

    private static func anyProbeCheckPassed(_ probe: HealthProbeSnapshot) -> Bool {
        allProbeChecks(probe).contains { $0.status == .passed }
    }

    private static func anyProbeCheckFailed(_ probe: HealthProbeSnapshot) -> Bool {
        allProbeChecks(probe).contains { $0.status == .failed }
    }

    private static func anyCriticalProbeCheckFailed(_ probe: HealthProbeSnapshot) -> Bool {
        criticalProbeChecks(probe).contains { $0.status == .failed }
    }

    private static func allCriticalProbeChecksFailed(_ probe: HealthProbeSnapshot) -> Bool {
        let attempted = criticalProbeChecks(probe).filter { $0.status != .notRun && $0.status != .skipped }
        return !attempted.isEmpty && attempted.allSatisfy { $0.status == .failed }
    }

    private static func allProbeChecks(_ probe: HealthProbeSnapshot) -> [HealthProbeCheck] {
        [
            probe.publicIP,
            probe.dnsLeak,
            probe.directHTTPS,
            probe.hostnameHTTPS,
            probe.resolverReachability,
            probe.tunnelHandshake
        ]
    }

    private static func criticalProbeChecks(_ probe: HealthProbeSnapshot) -> [HealthProbeCheck] {
        [
            probe.publicIP,
            probe.directHTTPS,
            probe.resolverReachability,
            probe.tunnelHandshake
        ]
    }

    private static func totalARQQueueRejects(_ metrics: TunnelMetrics) -> UInt64 {
        [
            metrics.arqDataPacketsQueueRejected,
            metrics.arqDataResendsRejected,
            metrics.arqDataNackPacketsRejected,
            metrics.arqControlPacketsQueueRejected,
            metrics.arqControlResendsRejected
        ].compactMap { $0 }.reduce(0, +)
    }

    private static func disconnectedEvidence(vpnStatus: NEVPNStatus, metrics: TunnelMetrics?) -> [String] {
        var evidence = [L10n.string("iOS status is %@.", vpnStatus.displayName)]
        guard let metrics else {
            return evidence
        }

        let metricsAge = max(0, Date().timeIntervalSince(metrics.updatedAt))
        evidence.append(
            L10n.string(
                "Last extension metrics were %@ old: status=%@ phase=%@ engine=%@.",
                formatSeconds(metricsAge),
                metrics.status,
                metrics.phase,
                metrics.engineRunning == true ? L10n.string("running") : L10n.string("not running")
            )
        )

        if let runtimeMode = metrics.runtimeMode {
            evidence.append(
                L10n.string(
                    "Runtime path: %@ (%@).",
                    runtimeMode,
                    metrics.runtimeModeSource ?? L10n.string("unknown source")
                )
            )
        }

        if let heartbeatAt = metrics.providerHeartbeatAt {
            let heartbeatAge = max(0, Date().timeIntervalSince(heartbeatAt))
            evidence.append(L10n.string("Provider heartbeat age: %@.", formatSeconds(heartbeatAge)))
        }

        if let reasonName = metrics.providerStopReasonName {
            evidence.append(
                L10n.string(
                    "Provider stop reason: %@ (%@).",
                    reasonName,
                    metrics.providerStopReasonRaw.map(String.init) ?? L10n.string("n/a")
                )
            )
        } else if metrics.status == "running", metrics.engineRunning == true, metricsAge >= 3 {
            evidence.append(
                L10n.string(
                    "No provider stop reason was recorded before iOS disconnected; check device logs for extension crash, jetsam, or NetworkExtension termination."
                )
            )
            // Tunnel extensions are killed at roughly 50 MB footprint; a high
            // final reading makes a memory kill the most likely explanation.
            if let footprint = metrics.memoryPhysicalFootprintBytes, footprint > 38 << 20 {
                evidence.append(
                    L10n.string(
                        "Last memory footprint was %@ — the extension was likely killed for approaching the ~50 MB memory limit during high traffic.",
                        ByteCountFormatter.string(fromByteCount: Int64(footprint), countStyle: .binary)
                    )
                )
            }
        }

        if let exitCode = metrics.hevExitCode {
            evidence.append(L10n.string("HEV runner exit code: %@.", "\(exitCode)"))
        }
        if let packetBridgeExitCode = metrics.packetBridgeExitCode {
            evidence.append(L10n.string("Packet bridge exit code: %@.", "\(packetBridgeExitCode)"))
        }

        let nativeEngineWriteErrors = metrics.nativePacketWriteErrors ?? 0
        let nativeFlowWriteFailures = metrics.nativePacketFlowWriteFailures ?? 0
        let nativeInvalidOutputPackets = metrics.nativePacketFlowInvalidOutputPackets ?? 0
        if nativeEngineWriteErrors > 0 || nativeFlowWriteFailures > 0 || nativeInvalidOutputPackets > 0 {
            evidence.append(
                L10n.string(
                    "Native packet output issues: engine writes %@; packet-flow rejects %@; invalid output %@.",
                    "\(nativeEngineWriteErrors)",
                    "\(nativeFlowWriteFailures)",
                    "\(nativeInvalidOutputPackets)"
                )
            )
        }
        let nativeTCPEndpointErrors = metrics.nativeTCPEndpointErrors ?? 0
        let nativeTCPEndpointResets = metrics.nativeTCPEndpointResets ?? 0
        if nativeTCPEndpointErrors > 0 || nativeTCPEndpointResets > 0 {
            evidence.append(
                L10n.string(
                    "Native TCP endpoint issues: errors %@; resets %@.",
                    "\(nativeTCPEndpointErrors)",
                    "\(nativeTCPEndpointResets)"
                )
            )
        }
        if let unsupportedUDP = metrics.nativeUnsupportedUDP, unsupportedUDP > 0 {
            let rejectedUDP = metrics.nativeUnsupportedUDPRejects ?? 0
            if let topPorts = metrics.nativeUnsupportedUDPTopPorts, !topPorts.isEmpty {
                evidence.append(
                    L10n.string(
                        "Native packet unsupported UDP packets: %@; rejected %@; top ports %@.",
                        "\(unsupportedUDP)",
                        "\(rejectedUDP)",
                        topPorts
                    )
                )
            } else {
                evidence.append(L10n.string("Native packet unsupported UDP packets: %@; rejected %@.", "\(unsupportedUDP)", "\(rejectedUDP)"))
            }
        }

        let arqAckRejects = metrics.arqDataAckPacketsRejected ?? 0
        let arqQueueRejects = totalARQQueueRejects(metrics)
        if arqAckRejects > 0 || arqQueueRejects > 0 {
            evidence.append(
                L10n.string(
                    "ARQ queue rejects: %@; ACK enqueue suppressions: %@.",
                    "\(arqQueueRejects)",
                    "\(arqAckRejects)"
                )
            )
        }

        if let residentBytes = metrics.memoryResidentBytes {
            evidence.append(L10n.string("Last provider RSS: %@.", ByteCountFormatter.string(fromByteCount: Int64(residentBytes), countStyle: .binary)))
        }
        return evidence
    }

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        if value < 10 {
            return String(format: "%.1fs", value)
        }
        return "\(Int(value.rounded()))s"
    }

    private static func timelineEvents(
        from log: String,
        metrics: TunnelMetrics?,
        probe: HealthProbeSnapshot?
    ) -> [HealthTimelineEvent] {
        let formatter = ISO8601DateFormatter()
        var events: [HealthTimelineEvent] = []

        for line in log.split(separator: "\n") {
            let pieces = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else {
                continue
            }
            let date = formatter.date(from: pieces[0])
            guard let event = timelineEvent(message: pieces[1], date: date) else {
                continue
            }
            events.append(event)
        }

        if let firstBridgeInputAt = metrics?.firstBridgeInputAt {
            events.append(HealthTimelineEvent(
                date: firstBridgeInputAt,
                title: L10n.string("First packet in"),
                detail: L10n.string("First packet from iOS apps reached the packet bridge."),
                severity: .success
            ))
        }

        if let firstBridgeOutputAt = metrics?.firstBridgeOutputAt {
            events.append(HealthTimelineEvent(
                date: firstBridgeOutputAt,
                title: L10n.string("First packet out"),
                detail: L10n.string("First packet from the packet bridge was returned to iOS."),
                severity: .success
            ))
        }

        if let metrics, metrics.totalBytes > 0 || metrics.bridgeInputPackets > 0 || metrics.bridgeOutputPackets > 0 {
            events.append(HealthTimelineEvent(
                date: metrics.updatedAt,
                title: L10n.string("Traffic observed"),
                detail: L10n.string("%@ up / %@ down packets", "\(metrics.uploadPackets)", "\(metrics.downloadPackets)"),
                severity: .success
            ))
        }

        if let probe {
            if probe.publicIP.status == .passed, let checkedAt = probe.publicIP.checkedAt {
                events.append(HealthTimelineEvent(
                    date: checkedAt,
                    title: L10n.string("Public IP probe passed"),
                    detail: probe.publicIP.detail,
                    severity: .success
                ))
            }

            events.append(HealthTimelineEvent(
                date: probe.updatedAt,
                title: L10n.string("Health checks updated"),
                detail: L10n.string(
                    "Public IP %@, DNS leak %@, 1.1.1.1 %@, resolver %@, handshake %@",
                    L10n.string(probe.publicIP.status.rawValue),
                    L10n.string(probe.dnsLeak.status.rawValue),
                    L10n.string(probe.directHTTPS.status.rawValue),
                    L10n.string(probe.resolverReachability.status.rawValue),
                    L10n.string(probe.tunnelHandshake.status.rawValue)
                ),
                severity: allCriticalProbeChecksFailed(probe) ? .failure : .success
            ))
        }

        return Array(events.sorted { lhs, rhs in
            (lhs.date ?? .distantPast) < (rhs.date ?? .distantPast)
        }.suffix(18))
    }

    private static func timelineEvent(message: String, date: Date?) -> HealthTimelineEvent? {
        let lower = message.lowercased()
        if lower.contains("traffic(packet-flow)") || lower.contains("(packet-flow):") {
            return nil
        }
        if lower.contains("health checks updated") || lower.contains("health checks completed") {
            return nil
        }
        if lower.contains("no buffer space available") {
            return HealthTimelineEvent(date: date, title: L10n.string("Bridge backpressure"), detail: message, severity: .warning)
        }
        if lower.contains("app connect requested") {
            return HealthTimelineEvent(date: date, title: L10n.string("Connect tapped"), detail: message, severity: .success)
        }
        if lower.contains("app selected profile") {
            return HealthTimelineEvent(date: date, title: L10n.string("Profile selected"), detail: message, severity: .success)
        }
        if lower.contains("app starting vpn tunnel") {
            return HealthTimelineEvent(date: date, title: L10n.string("VPN start requested"), detail: message, severity: .success)
        }
        if lower.contains("app vpn status changed") {
            return HealthTimelineEvent(date: date, title: L10n.string("iOS status changed"), detail: message, severity: .success)
        }
        if lower.contains("starting tunnel") {
            return HealthTimelineEvent(date: date, title: L10n.string("Extension started"), detail: message, severity: .success)
        }
        if lower.contains("network settings applied") {
            return HealthTimelineEvent(date: date, title: L10n.string("Network settings applied"), detail: message, severity: .success)
        }
        if lower.contains("applying network settings") {
            return nil
        }
        if lower.contains("starting masterdnsvpn") || lower.contains("starting vaydns") {
            return HealthTimelineEvent(date: date, title: L10n.string("Engine starting"), detail: message, severity: .success)
        }
        if lower.contains("engine started") {
            return HealthTimelineEvent(date: date, title: L10n.string("Engine running"), detail: message, severity: .success)
        }
        if lower.contains("hev") && lower.contains("bridge created") {
            return HealthTimelineEvent(date: date, title: L10n.string("Packet bridge created"), detail: message, severity: .success)
        }
        if lower.contains("hevsocks5tunnel started") {
            return HealthTimelineEvent(date: date, title: L10n.string("Hev started"), detail: message, severity: .success)
        }
        if lower.contains("hevsocks5tunnel exited") {
            return HealthTimelineEvent(date: date, title: L10n.string("Hev exited"), detail: message, severity: .failure)
        }
        if lower.contains("packet bridge exited") {
            return HealthTimelineEvent(date: date, title: L10n.string("Packet bridge exited"), detail: message, severity: .failure)
        }
        if lower.contains("provider stop completed") {
            return HealthTimelineEvent(date: date, title: L10n.string("Provider stopped"), detail: message, severity: .warning)
        }
        if lower.contains("stopping tunnel") || lower.contains("disconnect requested") {
            return HealthTimelineEvent(date: date, title: L10n.string("Disconnect"), detail: message, severity: .warning)
        }
        if lower.contains("failed") || lower.contains("error") {
            return HealthTimelineEvent(date: date, title: L10n.string("Failure"), detail: message, severity: .failure)
        }
        return nil
    }
}

enum HealthProbeKind: String, CaseIterable, Identifiable {
    case publicIP
    case dnsLeak
    case directHTTPS
    case resolverReachability
    case tunnelHandshake

    var id: String { rawValue }

    var title: String {
        switch self {
        case .publicIP:
            return L10n.string("Check Public IP")
        case .dnsLeak:
            return L10n.string("Check DNS Leak")
        case .directHTTPS:
            return L10n.string("Check 1.1.1.1/help")
        case .resolverReachability:
            return L10n.string("Check Resolver")
        case .tunnelHandshake:
            return L10n.string("Check Handshake")
        }
    }

    var systemImage: String {
        switch self {
        case .publicIP:
            return "globe.americas"
        case .dnsLeak:
            return "network"
        case .directHTTPS:
            return "lock"
        case .resolverReachability:
            return "dot.radiowaves.left.and.right"
        case .tunnelHandshake:
            return "point.3.connected.trianglepath.dotted"
        }
    }
}

@MainActor
final class HealthModel: ObservableObject {
    @Published var probeSnapshot: HealthProbeSnapshot?
    @Published var isRunningChecks = false
    @Published var runningProbeKind: HealthProbeKind?
    @Published var lastError: String?

    private let repository = ProfileRepository()
    private var automaticRunProfileID: UUID?

    func reload() {
        do {
            probeSnapshot = try repository.readHealthProbeSnapshot()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func resetAutomaticRun() {
        automaticRunProfileID = nil
    }

    func runAutomaticIfNeeded(profile: VPNProfile, vpnStatus: NEVPNStatus, metrics: TunnelMetrics?) async {
        guard vpnStatus == .connected else {
            automaticRunProfileID = nil
            return
        }
        guard automaticRunProfileID != profile.id else {
            return
        }
        automaticRunProfileID = profile.id
        if profile.tunnelProtocol == .masterdns {
            await runStartupChecks(profile: profile, vpnStatus: vpnStatus, metrics: metrics, trigger: "on-connect")
        } else {
            await runAllChecks(profile: profile, vpnStatus: vpnStatus, metrics: metrics, trigger: "on-connect")
        }
    }

    func runStartupChecks(
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        trigger: String
    ) async {
        guard !isRunningChecks else {
            return
        }
        isRunningChecks = true
        runningProbeKind = nil
        lastError = nil
        let snapshot = await HealthProbeRunner.runStartup(
            profile: profile,
            vpnStatus: vpnStatus,
            metrics: metrics,
            previous: currentSnapshot(for: profile),
            trigger: trigger
        )
        await finish(snapshot)
        isRunningChecks = false
    }

    func runAllChecks(
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        trigger: String = "manual-all"
    ) async {
        guard !isRunningChecks else {
            return
        }
        isRunningChecks = true
        runningProbeKind = nil
        lastError = nil
        let snapshot = await HealthProbeRunner.runAll(
            profile: profile,
            vpnStatus: vpnStatus,
            metrics: metrics,
            previous: currentSnapshot(for: profile),
            trigger: trigger
        )
        await finish(snapshot)
        isRunningChecks = false
    }

    func runCheck(
        _ kind: HealthProbeKind,
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?
    ) async {
        guard !isRunningChecks else {
            return
        }
        isRunningChecks = true
        runningProbeKind = kind
        lastError = nil
        let snapshot = await HealthProbeRunner.run(
            kind: kind,
            profile: profile,
            vpnStatus: vpnStatus,
            metrics: metrics,
            previous: currentSnapshot(for: profile)
        )
        await finish(snapshot)
        runningProbeKind = nil
        isRunningChecks = false
    }

    private func currentSnapshot(for profile: VPNProfile) -> HealthProbeSnapshot? {
        if probeSnapshot?.profileID == profile.id {
            return probeSnapshot
        }
        return (try? repository.readHealthProbeSnapshot()).flatMap { $0.profileID == profile.id ? $0 : nil }
    }

    private func finish(_ snapshot: HealthProbeSnapshot) async {
        do {
            try repository.writeHealthProbeSnapshot(snapshot)
            try? repository.appendTunnelLog(
                "health checks updated: trigger=\(snapshot.trigger) " +
                "publicIP=\(snapshot.publicIP.status.rawValue) " +
                "dnsLeak=\(snapshot.dnsLeak.status.rawValue) " +
                "directHTTPS=\(snapshot.directHTTPS.status.rawValue) " +
                "resolver=\(snapshot.resolverReachability.status.rawValue) " +
                "handshake=\(snapshot.tunnelHandshake.status.rawValue)"
            )
            probeSnapshot = snapshot
        } catch {
            lastError = error.localizedDescription
        }
    }
}

enum HealthProbeRunner {
    static func runAll(
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        previous: HealthProbeSnapshot?,
        trigger: String
    ) async -> HealthProbeSnapshot {
        let startedAt = Date()
        var snapshot = baseSnapshot(profile: profile, trigger: trigger, startedAt: startedAt, previous: previous)

        guard vpnStatus == .connected else {
            let skipped = skipped(L10n.string("Unavailable because tunnel is %@", vpnStatus.displayName), at: startedAt)
            snapshot.publicIP = skipped
            snapshot.dnsLeak = skipped
            snapshot.directHTTPS = skipped
            snapshot.hostnameHTTPS = skipped
            snapshot.resolverReachability = skipped
            snapshot.tunnelHandshake = skipped
            snapshot.updatedAt = startedAt
            return snapshot
        }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        async let publicIPResult = publicIPCheck(session: session)
        async let dnsLeakResult = dnsLeakCheck(session: session, expectedDNSServers: profile.expectedDNSServers)
        async let directHTTPS = httpCheck(
            session: session,
            url: URL(string: "https://1.1.1.1/help")!,
            successDetail: L10n.string("1.1.1.1/help reachable")
        )
        async let hostnameHTTPS = httpCheck(
            session: session,
            url: URL(string: "https://www.apple.com/library/test/success.html")!,
            successDetail: L10n.string("Hostname HTTPS reachable")
        )
        async let resolverReachability = resolverReachabilityCheck(profile: profile, metrics: metrics, session: session)
        let tunnelHandshake = tunnelHandshakeCheck(profile: profile, metrics: metrics)

        let (publicIP, observedIP) = await publicIPResult
        let (dnsLeak, reportedDNS) = await dnsLeakResult
        snapshot.publicIP = publicIP
        snapshot.observedExitIP = observedIP
        snapshot.expectedExitIPMatched = exitIPMatched(expected: profile.expectedExitIP, observed: observedIP)
        snapshot.dnsLeak = dnsLeak
        snapshot.reportedDNSServers = reportedDNS
        snapshot.directHTTPS = await directHTTPS
        snapshot.hostnameHTTPS = await hostnameHTTPS
        snapshot.resolverReachability = await resolverReachability
        snapshot.tunnelHandshake = tunnelHandshake
        snapshot.updatedAt = Date()
        return snapshot
    }

    static func runStartup(
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        previous: HealthProbeSnapshot?,
        trigger: String
    ) async -> HealthProbeSnapshot {
        let startedAt = Date()
        var snapshot = baseSnapshot(profile: profile, trigger: trigger, startedAt: startedAt, previous: previous)

        guard vpnStatus == .connected else {
            let skipped = skipped(L10n.string("Unavailable because tunnel is %@", vpnStatus.displayName), at: startedAt)
            snapshot.publicIP = skipped
            snapshot.dnsLeak = skipped
            snapshot.directHTTPS = skipped
            snapshot.hostnameHTTPS = skipped
            snapshot.resolverReachability = skipped
            snapshot.tunnelHandshake = skipped
            snapshot.updatedAt = startedAt
            return snapshot
        }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        let (publicIP, observedIP) = await publicIPCheck(session: session)
        snapshot.publicIP = publicIP
        snapshot.observedExitIP = observedIP
        snapshot.expectedExitIPMatched = exitIPMatched(expected: profile.expectedExitIP, observed: observedIP)
        snapshot.resolverReachability = await resolverReachabilityCheck(profile: profile, metrics: metrics, session: session)
        snapshot.tunnelHandshake = tunnelHandshakeCheck(profile: profile, metrics: metrics)
        let skipped = skipped(L10n.string("Skipped during lightweight startup check"), at: startedAt)
        snapshot.dnsLeak = skipped
        snapshot.directHTTPS = skipped
        snapshot.hostnameHTTPS = skipped
        snapshot.updatedAt = Date()
        return snapshot
    }

    static func run(
        kind: HealthProbeKind,
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        previous: HealthProbeSnapshot?
    ) async -> HealthProbeSnapshot {
        let startedAt = Date()
        var snapshot = baseSnapshot(profile: profile, trigger: "manual-\(kind.rawValue)", startedAt: startedAt, previous: previous)

        guard vpnStatus == .connected else {
            let check = skipped(L10n.string("Unavailable because tunnel is %@", vpnStatus.displayName), at: startedAt)
            apply(check: check, kind: kind, to: &snapshot)
            snapshot.updatedAt = startedAt
            return snapshot
        }

        let session = makeSession()
        defer { session.finishTasksAndInvalidate() }

        switch kind {
        case .publicIP:
            let (check, observedIP) = await publicIPCheck(session: session)
            snapshot.publicIP = check
            snapshot.observedExitIP = observedIP
            snapshot.expectedExitIPMatched = exitIPMatched(expected: profile.expectedExitIP, observed: observedIP)
        case .dnsLeak:
            let (check, reportedDNS) = await dnsLeakCheck(session: session, expectedDNSServers: profile.expectedDNSServers)
            snapshot.dnsLeak = check
            snapshot.reportedDNSServers = reportedDNS
        case .directHTTPS:
            snapshot.directHTTPS = await httpCheck(
                session: session,
                url: URL(string: "https://1.1.1.1/help")!,
                successDetail: L10n.string("1.1.1.1/help reachable")
            )
        case .resolverReachability:
            snapshot.resolverReachability = await resolverReachabilityCheck(profile: profile, metrics: metrics, session: session)
        case .tunnelHandshake:
            snapshot.tunnelHandshake = tunnelHandshakeCheck(profile: profile, metrics: metrics)
        }

        snapshot.updatedAt = Date()
        return snapshot
    }

    private static func baseSnapshot(
        profile: VPNProfile,
        trigger: String,
        startedAt: Date,
        previous: HealthProbeSnapshot?
    ) -> HealthProbeSnapshot {
        var snapshot = previous ?? HealthProbeSnapshot(
            profileID: profile.id,
            profileName: profile.name,
            trigger: trigger,
            startedAt: startedAt,
            updatedAt: startedAt,
            expectedExitIP: profile.expectedExitIP,
            observedExitIP: nil,
            expectedExitIPMatched: nil,
            expectedDNSServers: profile.expectedDNSServers
        )
        snapshot.profileName = profile.name
        snapshot.trigger = trigger
        snapshot.startedAt = startedAt
        snapshot.updatedAt = startedAt
        snapshot.expectedExitIP = profile.expectedExitIP
        snapshot.expectedDNSServers = profile.expectedDNSServers
        return snapshot
    }

    private static func apply(check: HealthProbeCheck, kind: HealthProbeKind, to snapshot: inout HealthProbeSnapshot) {
        switch kind {
        case .publicIP:
            snapshot.publicIP = check
        case .dnsLeak:
            snapshot.dnsLeak = check
        case .directHTTPS:
            snapshot.directHTTPS = check
        case .resolverReachability:
            snapshot.resolverReachability = check
        case .tunnelHandshake:
            snapshot.tunnelHandshake = check
        }
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }

    private static func publicIPCheck(session: URLSession) async -> (HealthProbeCheck, String?) {
        let startedAt = Date()
        do {
            let request = URLRequest(url: URL(string: "https://api64.ipify.org?format=json")!)
            let (data, response) = try await session.data(for: request)
            let duration = milliseconds(since: startedAt)
            guard let http = response as? HTTPURLResponse else {
                return (failed(L10n.string("Public IP response was not HTTP"), duration: duration, statusCode: nil), nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                return (failed(L10n.string("Public IP check returned HTTP %@", "\(http.statusCode)"), duration: duration, statusCode: http.statusCode), nil)
            }
            let decoded = try JSONDecoder().decode(PublicIPResponse.self, from: data)
            guard !decoded.ip.isEmpty else {
                return (failed(L10n.string("Public IP response did not include an IP"), duration: duration, statusCode: http.statusCode), nil)
            }
            return (
                HealthProbeCheck(
                    status: .passed,
                    checkedAt: Date(),
                    durationMilliseconds: duration,
                    statusCode: http.statusCode,
                    detail: L10n.string("Observed %@", decoded.ip)
                ),
                decoded.ip
            )
        } catch {
            return (failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil), nil)
        }
    }

    private static func dnsLeakCheck(
        session: URLSession,
        expectedDNSServers: [String]?
    ) async -> (HealthProbeCheck, [String]) {
        let startedAt = Date()
        do {
            let host = "\(randomToken(length: 32)).edns.ip-api.com"
            let request = URLRequest(url: URL(string: "http://\(host)/json")!)
            let (data, response) = try await session.data(for: request)
            let duration = milliseconds(since: startedAt)
            guard let http = response as? HTTPURLResponse else {
                return (failed(L10n.string("DNS leak response was not HTTP"), duration: duration, statusCode: nil), [])
            }
            guard (200..<300).contains(http.statusCode) else {
                return (failed(L10n.string("DNS leak check returned HTTP %@", "\(http.statusCode)"), duration: duration, statusCode: http.statusCode), [])
            }

            let reportedServers = extractDNSResolverIPs(from: data)
            guard !reportedServers.isEmpty else {
                return (
                    HealthProbeCheck(
                        status: .warning,
                        checkedAt: Date(),
                        durationMilliseconds: duration,
                        statusCode: http.statusCode,
                        detail: L10n.string("DNS leak endpoint answered, but no resolver IPs were reported")
                    ),
                    []
                )
            }

            let expected = Set((expectedDNSServers ?? []).map(normalizedIPAddress))
            if expected.isEmpty {
                return (
                    HealthProbeCheck(
                        status: .warning,
                        checkedAt: Date(),
                        durationMilliseconds: duration,
                        statusCode: http.statusCode,
                        detail: L10n.string("Reported DNS resolvers: %@; configure expectedDNSServers for pass/fail", reportedServers.joined(separator: ", "))
                    ),
                    reportedServers
                )
            }

            let unexpected = reportedServers.filter { !expected.contains(normalizedIPAddress($0)) }
            if unexpected.isEmpty {
                return (
                    HealthProbeCheck(
                        status: .passed,
                        checkedAt: Date(),
                        durationMilliseconds: duration,
                        statusCode: http.statusCode,
                        detail: L10n.string("Reported DNS resolvers matched expected set: %@", reportedServers.joined(separator: ", "))
                    ),
                    reportedServers
                )
            }

            return (
                failed(
                    L10n.string("Unexpected DNS resolvers: %@; reported %@", unexpected.joined(separator: ", "), reportedServers.joined(separator: ", ")),
                    duration: duration,
                    statusCode: http.statusCode
                ),
                reportedServers
            )
        } catch {
            return (failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil), [])
        }
    }

    private static func httpCheck(session: URLSession, url: URL, successDetail: String) async -> HealthProbeCheck {
        let startedAt = Date()
        do {
            let request = URLRequest(url: url)
            let (_, response) = try await session.data(for: request)
            let duration = milliseconds(since: startedAt)
            guard let http = response as? HTTPURLResponse else {
                return failed(L10n.string("Response was not HTTP"), duration: duration, statusCode: nil)
            }
            guard (200..<400).contains(http.statusCode) else {
                return failed(L10n.string("HTTP %@", "\(http.statusCode)"), duration: duration, statusCode: http.statusCode)
            }
            return HealthProbeCheck(
                status: .passed,
                checkedAt: Date(),
                durationMilliseconds: duration,
                statusCode: http.statusCode,
                detail: successDetail
            )
        } catch {
            return failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil)
        }
    }

    private static func resolverReachabilityCheck(
        profile: VPNProfile,
        metrics: TunnelMetrics?,
        session: URLSession
    ) async -> HealthProbeCheck {
        let startedAt = Date()
        guard let resolver = profile.resolvers.first else {
            return failed(L10n.string("Profile has no resolver"), duration: 0, statusCode: nil)
        }

        if profile.tunnelProtocol == .masterdns {
            guard let metrics else {
                return HealthProbeCheck.notRun(L10n.string("Waiting for MasterDnsVPN engine metrics"))
            }
            let age = Int(Date().timeIntervalSince(metrics.updatedAt))
            if (metrics.acceptedResolvers ?? 0) > 0 {
                return HealthProbeCheck(
                    status: .passed,
                    checkedAt: Date(),
                    durationMilliseconds: milliseconds(since: startedAt),
                    statusCode: nil,
                    detail: L10n.string("Engine accepted resolver %@ %@ ago", metrics.resolverAddress ?? resolver.address, L10n.string("%ds", age))
                )
            }
            if (metrics.rejectedResolvers ?? 0) > 0 {
                return failed(
                    L10n.string("Engine rejected %@ resolver(s); last resolver %@", "\(metrics.rejectedResolvers ?? 0)", metrics.resolverAddress ?? resolver.address),
                    duration: milliseconds(since: startedAt),
                    statusCode: nil
                )
            }
            return HealthProbeCheck.notRun(L10n.string("Waiting for MasterDnsVPN MTU results for %@", metrics.resolverAddress ?? resolver.address))
        }

        let query = dnsQueryData(hostname: "example.com", recordType: 1)
        switch resolver.type.lowercased() {
        case "udp":
            let parsed = parseResolverAddress(resolver.address, defaultPort: 53)
            return await udpDNSProbe(host: parsed.host, port: parsed.port, query: query, startedAt: startedAt)
        case "doh":
            guard let url = dohURL(for: resolver.address) else {
                return failed(L10n.string("Invalid DoH resolver URL: %@", resolver.address), duration: milliseconds(since: startedAt), statusCode: nil)
            }
            return await dohDNSProbe(url: url, query: query, session: session, startedAt: startedAt)
        case "dot":
            let parsed = parseResolverAddress(resolver.address, defaultPort: 853)
            return await dotDNSProbe(host: parsed.host, port: parsed.port, query: query, startedAt: startedAt)
        default:
            return failed(L10n.string("Unsupported resolver type: %@", resolver.type), duration: milliseconds(since: startedAt), statusCode: nil)
        }
    }

    private static func tunnelHandshakeCheck(profile: VPNProfile, metrics: TunnelMetrics?) -> HealthProbeCheck {
        let startedAt = Date()
        guard let metrics else {
            return failed(L10n.string("No extension metrics are available yet"), duration: milliseconds(since: startedAt), statusCode: nil)
        }
        if metrics.status == "failed" {
            return failed(L10n.string("Extension status is failed: %@", metrics.lastError ?? metrics.lastLogLine ?? L10n.string("no detail")), duration: milliseconds(since: startedAt), statusCode: nil)
        }
        if metrics.engineRunning == false {
            return failed(L10n.string("Engine is not running"), duration: milliseconds(since: startedAt), statusCode: nil)
        }
        if profile.tunnelProtocol == .masterdns, metrics.sessionID == nil {
            return failed(L10n.string("MasterDnsVPN session ID is not available yet"), duration: milliseconds(since: startedAt), statusCode: nil)
        }
        if profile.tunnelProtocol == .masterdns, metrics.acceptedResolvers == 0 {
            return failed(L10n.string("MasterDnsVPN did not accept any resolver"), duration: milliseconds(since: startedAt), statusCode: nil)
        }

        var detail = L10n.string("Extension %@, phase %@", metrics.status, metrics.phase)
        if let sessionID = metrics.sessionID {
            detail += L10n.string(", session %@", "\(sessionID)")
        }
        if let acceptedResolvers = metrics.acceptedResolvers {
            detail += L10n.string(", accepted resolvers %@", "\(acceptedResolvers)")
        }
        return HealthProbeCheck(
            status: .passed,
            checkedAt: Date(),
            durationMilliseconds: milliseconds(since: startedAt),
            statusCode: nil,
            detail: detail
        )
    }

    private static func dohDNSProbe(
        url: URL,
        query: Data,
        session: URLSession,
        startedAt: Date
    ) async -> HealthProbeCheck {
        do {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = query
            request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
            request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            let duration = milliseconds(since: startedAt)
            guard let http = response as? HTTPURLResponse else {
                return failed(L10n.string("DoH response was not HTTP"), duration: duration, statusCode: nil)
            }
            guard (200..<300).contains(http.statusCode) else {
                return failed(L10n.string("DoH resolver returned HTTP %@", "\(http.statusCode)"), duration: duration, statusCode: http.statusCode)
            }
            guard data.count >= 12 else {
                return failed(L10n.string("DoH resolver returned a short DNS response"), duration: duration, statusCode: http.statusCode)
            }
            return HealthProbeCheck(
                status: .passed,
                checkedAt: Date(),
                durationMilliseconds: duration,
                statusCode: http.statusCode,
                detail: L10n.string("DoH resolver answered %@ bytes", "\(data.count)")
            )
        } catch {
            return failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil)
        }
    }

    private static func udpDNSProbe(
        host: String,
        port: UInt16,
        query: Data,
        startedAt: Date
    ) async -> HealthProbeCheck {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return failed(L10n.string("Invalid UDP resolver port %@", "\(port)"), duration: milliseconds(since: startedAt), statusCode: nil)
        }

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "VpnDad.UDPResolverProbe.\(UUID().uuidString)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .udp)
            let oneShot = OneShot()
            let timeout = DispatchWorkItem {
                oneShot.run {
                    connection.cancel()
                    continuation.resume(returning: failed(L10n.string("UDP resolver timed out at %@:%@", host, "\(port)"), duration: milliseconds(since: startedAt), statusCode: nil))
                }
            }

            func finish(_ check: HealthProbeCheck) {
                timeout.cancel()
                oneShot.run {
                    connection.cancel()
                    continuation.resume(returning: check)
                }
            }

            queue.asyncAfter(deadline: .now() + 5, execute: timeout)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: query, completion: .contentProcessed { error in
                        if let error {
                            finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                            return
                        }
                        connection.receiveMessage { data, _, _, error in
                            if let error {
                                finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                                return
                            }
                            guard let data, data.count >= 12 else {
                                finish(failed(L10n.string("UDP resolver returned no DNS response"), duration: milliseconds(since: startedAt), statusCode: nil))
                                return
                            }
                            finish(HealthProbeCheck(
                                status: .passed,
                                checkedAt: Date(),
                                durationMilliseconds: milliseconds(since: startedAt),
                                statusCode: nil,
                                detail: L10n.string("UDP resolver %@:%@ answered %@ bytes", host, "\(port)", "\(data.count)")
                            ))
                        }
                    })
                case .failed(let error):
                    finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func dotDNSProbe(
        host: String,
        port: UInt16,
        query: Data,
        startedAt: Date
    ) async -> HealthProbeCheck {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            return failed(L10n.string("Invalid DoT resolver port %@", "\(port)"), duration: milliseconds(since: startedAt), statusCode: nil)
        }

        var framedQuery = Data()
        appendUInt16(UInt16(query.count), to: &framedQuery)
        framedQuery.append(query)
        let queryFrame = framedQuery

        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "VpnDad.DoTResolverProbe.\(UUID().uuidString)")
            let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tls)
            let oneShot = OneShot()
            let timeout = DispatchWorkItem {
                oneShot.run {
                    connection.cancel()
                    continuation.resume(returning: failed(L10n.string("DoT resolver timed out at %@:%@", host, "\(port)"), duration: milliseconds(since: startedAt), statusCode: nil))
                }
            }

            func finish(_ check: HealthProbeCheck) {
                timeout.cancel()
                oneShot.run {
                    connection.cancel()
                    continuation.resume(returning: check)
                }
            }

            queue.asyncAfter(deadline: .now() + 6, execute: timeout)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: queryFrame, completion: .contentProcessed { error in
                        if let error {
                            finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                            return
                        }
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { prefix, _, _, error in
                            if let error {
                                finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                                return
                            }
                            guard let prefix, prefix.count == 2 else {
                                finish(failed(L10n.string("DoT resolver returned no length prefix"), duration: milliseconds(since: startedAt), statusCode: nil))
                                return
                            }
                            let responseLength = Int(prefix[prefix.startIndex]) << 8 | Int(prefix[prefix.index(after: prefix.startIndex)])
                            connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, responseLength)) { response, _, _, error in
                                if let error {
                                    finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                                    return
                                }
                                guard let response, response.count >= 12 else {
                                    finish(failed(L10n.string("DoT resolver returned a short DNS response"), duration: milliseconds(since: startedAt), statusCode: nil))
                                    return
                                }
                                finish(HealthProbeCheck(
                                    status: .passed,
                                    checkedAt: Date(),
                                    durationMilliseconds: milliseconds(since: startedAt),
                                    statusCode: nil,
                                    detail: L10n.string("DoT resolver %@:%@ answered %@ bytes", host, "\(port)", "\(response.count)")
                                ))
                            }
                        }
                    })
                case .failed(let error):
                    finish(failed(error.localizedDescription, duration: milliseconds(since: startedAt), statusCode: nil))
                case .cancelled:
                    break
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func failed(_ detail: String, duration: Int, statusCode: Int?) -> HealthProbeCheck {
        HealthProbeCheck(
            status: .failed,
            checkedAt: Date(),
            durationMilliseconds: duration,
            statusCode: statusCode,
            detail: detail
        )
    }

    private static func skipped(_ detail: String, at date: Date = Date()) -> HealthProbeCheck {
        HealthProbeCheck(
            status: .skipped,
            checkedAt: date,
            durationMilliseconds: nil,
            statusCode: nil,
            detail: detail
        )
    }

    private static func milliseconds(since date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) * 1000))
    }

    private static func exitIPMatched(expected: String?, observed: String?) -> Bool? {
        guard let expected, let observed else {
            return nil
        }
        return normalizedIPAddress(expected) == normalizedIPAddress(observed)
    }

    private static func normalizedIPAddress(_ value: String) -> String {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN))
            return String(cString: buffer)
        }

        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &ipv6, &buffer, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buffer).lowercased()
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func extractDNSResolverIPs(from data: Data) -> [String] {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let dictionary = object as? [String: Any]
        else {
            return []
        }

        var values = Set<String>()
        if let dns = dictionary["dns"] {
            collectIPs(from: dns, into: &values)
        }
        for key in ["resolver", "resolvers", "dnsServers", "servers"] {
            if let value = dictionary[key] {
                collectIPs(from: value, into: &values)
            }
        }
        return values.sorted()
    }

    private static func collectIPs(from value: Any, into values: inout Set<String>) {
        switch value {
        case let string as String:
            let normalized = normalizedIPAddress(string)
            if isIPAddress(normalized) {
                values.insert(normalized)
            }
        case let array as [Any]:
            array.forEach { collectIPs(from: $0, into: &values) }
        case let dictionary as [String: Any]:
            dictionary.values.forEach { collectIPs(from: $0, into: &values) }
        default:
            break
        }
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private static func randomToken(length: Int) -> String {
        let symbols = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).compactMap { _ in symbols.randomElement() })
    }

    private static func dnsQueryData(hostname: String, recordType: UInt16) -> Data {
        var data = Data()
        appendUInt16(UInt16.random(in: 1...UInt16.max), to: &data)
        appendUInt16(0x0100, to: &data)
        appendUInt16(1, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        appendUInt16(0, to: &data)
        for label in hostname.split(separator: ".") {
            let bytes = Array(label.utf8)
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        data.append(0)
        appendUInt16(recordType, to: &data)
        appendUInt16(1, to: &data)
        return data
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func parseResolverAddress(_ address: String, defaultPort: UInt16) -> ParsedNetworkAddress {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["),
           let end = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let remainder = trimmed[trimmed.index(after: end)...]
            let portText = String(remainder.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            let port = UInt16(portText) ?? defaultPort
            return ParsedNetworkAddress(host: host, port: port)
        }

        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2, let port = UInt16(parts[1]) {
            return ParsedNetworkAddress(host: String(parts[0]), port: port)
        }

        return ParsedNetworkAddress(host: trimmed, port: defaultPort)
    }

    private static func dohURL(for address: String) -> URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("http://") {
            return URL(string: trimmed)
        }
        return URL(string: "https://\(trimmed)/dns-query")
    }
}

enum DiagnosticBundleBuilder {
    static func makeData(
        profile: VPNProfile,
        vpnStatus: NEVPNStatus,
        metrics: TunnelMetrics?,
        probe: HealthProbeSnapshot?,
        report: TunnelHealthReport,
        tunnelLog: String
    ) throws -> Data {
        let info = Bundle.main.infoDictionary ?? [:]
        let bundle = DiagnosticBundle(
            generatedAt: Date(),
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            appBuild: info["CFBundleVersion"] as? String ?? "unknown",
            vpnStatus: vpnStatus.displayName,
            profile: DiagnosticProfileSummary(profile: profile),
            healthReport: DiagnosticHealthReport(report: report),
            latestMetrics: metrics.map(DiagnosticMetricsSummary.init(metrics:)),
            latestProbeSnapshot: probe?.profileID == profile.id ? probe : nil,
            lastLogs: redact(tunnelLog)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    private static func redact(_ text: String) -> String {
        var redacted = text
        let patterns = [
            #""encryptionKey"\s*:\s*"[^"]+""#,
            #""publicKey"\s*:\s*"[^"]+""#,
            #"encryptionKey=[^\s]+"#,
            #"publicKey=[^\s]+"#
        ]
        for pattern in patterns {
            redacted = redacted.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        return redacted
    }
}

private struct ParsedNetworkAddress {
    var host: String
    var port: UInt16
}

private final class OneShot {
    private let lock = NSLock()
    private var used = false

    func run(_ body: () -> Void) {
        lock.lock()
        guard !used else {
            lock.unlock()
            return
        }
        used = true
        lock.unlock()
        body()
    }
}

private struct PublicIPResponse: Decodable {
    let ip: String
}

private struct DiagnosticBundle: Encodable {
    var generatedAt: Date
    var appVersion: String
    var appBuild: String
    var vpnStatus: String
    var profile: DiagnosticProfileSummary
    var healthReport: DiagnosticHealthReport
    var latestMetrics: DiagnosticMetricsSummary?
    var latestProbeSnapshot: HealthProbeSnapshot?
    var lastLogs: String
}

private struct DiagnosticProfileSummary: Encodable {
    var id: UUID
    var name: String
    var tunnelProtocol: String
    var domain: String
    var resolvers: [String]
    var expectedExitIP: String?
    var expectedDNSServers: [String]?

    init(profile: VPNProfile) {
        id = profile.id
        name = profile.name
        tunnelProtocol = profile.tunnelProtocol.rawValue
        domain = profile.domain
        resolvers = profile.resolvers.map { "\($0.type):\($0.address)" }
        expectedExitIP = profile.expectedExitIP
        expectedDNSServers = profile.expectedDNSServers
    }
}

private struct DiagnosticHealthReport: Encodable {
    var verdict: String
    var summary: String
    var evidence: [String]
    var timeline: [DiagnosticTimelineItem]

    init(report: TunnelHealthReport) {
        verdict = report.verdict.rawValue
        summary = report.summary
        evidence = report.evidence
        timeline = report.timeline.map(DiagnosticTimelineItem.init(event:))
    }
}

private struct DiagnosticTimelineItem: Encodable {
    var timestamp: Date?
    var title: String
    var detail: String
    var severity: String

    init(event: HealthTimelineEvent) {
        timestamp = event.date
        title = event.title
        detail = event.detail
        severity = event.severity.rawValue
    }
}

private struct DiagnosticMetricsSummary: Encodable {
    var status: String
    var phase: String
    var profileName: String
    var tunnelProtocol: String
    var socksAddress: String
    var startedAt: Date?
    var updatedAt: Date
    var uptimeSeconds: Int
    var providerStartedAt: Date?
    var providerHeartbeatAt: Date?
    var providerLastTelemetryWriteAt: Date?
    var providerStoppingAt: Date?
    var providerStoppedAt: Date?
    var providerStopReasonRaw: Int?
    var providerStopReasonName: String?
    var providerLastLifecycleEvent: String?
    var hevRunning: Bool?
    var hevExitCode: Int?
    var hevExitedAt: Date?
    var packetBridgeExitedAt: Date?
    var packetBridgeExitCode: Int?
    var memoryResidentBytes: UInt64?
    var memoryPhysicalFootprintBytes: UInt64?
    var threadCount: Int?
    var openFileDescriptorCount: Int?
    var resolverAddress: String?
    var sessionID: Int?
    var uploadMTU: Int?
    var downloadMTU: Int?
    var acceptedResolvers: Int?
    var rejectedResolvers: Int?
    var sendsPerPacket: Int?
    var duplicateCopiesPerPacket: Int?
    var uploadPackets: UInt64
    var downloadPackets: UInt64
    var uploadBytes: UInt64
    var downloadBytes: UInt64
    var totalBytes: UInt64
    var uploadBytesPerSecond: Double
    var downloadBytesPerSecond: Double
    var totalBytesPerSecond: Double
    var bridgeInputPackets: UInt64
    var bridgeInputBytes: UInt64
    var bridgeOutputPackets: UInt64
    var bridgeOutputBytes: UInt64
    var firstBridgeInputAt: Date?
    var firstBridgeOutputAt: Date?
    var bridgeReadErrors: UInt64
    var bridgeWriteErrors: UInt64
    var bridgeShortWrites: UInt64
    var lastBridgeError: String?
    var engineRunning: Bool?
    var engineStartedAt: String?
    var engineLastError: String?
    var lastLogLine: String?
    var lastError: String?
    var arqStreamsCreated: UInt64?
    var arqStreamsClosed: UInt64?
    var arqStreamsActive: UInt64?
    var arqDataPacketsRead: UInt64?
    var arqDataPacketsQueued: UInt64?
    var arqDataPacketsQueueRejected: UInt64?
    var arqDataPacketsDequeued: UInt64?
    var arqDataPacketsAcked: UInt64?
    var arqDataPacketsReceived: UInt64?
    var arqDataAckPacketsSent: UInt64?
    var arqDataAckPacketsRejected: UInt64?
    var arqDataNackPacketsSent: UInt64?
    var arqDataNackPacketsRejected: UInt64?
    var arqDataNackPacketsReceived: UInt64?
    var arqDataResendsQueued: UInt64?
    var arqDataResendsRejected: UInt64?
    var arqDataNackResendsQueued: UInt64?
    var arqDataNackResendsRejected: UInt64?
    var arqDataTimeoutResendsQueued: UInt64?
    var arqDataTimeoutResendsRejected: UInt64?
    var arqDataMaxRetriesExceeded: UInt64?
    var arqDataTTLExpired: UInt64?
    var arqControlPacketsQueued: UInt64?
    var arqControlPacketsQueueRejected: UInt64?
    var arqControlPacketsDequeued: UInt64?
    var arqControlPacketsAcked: UInt64?
    var arqControlResendsQueued: UInt64?
    var arqControlResendsRejected: UInt64?
    var arqControlMaxRetriesExceeded: UInt64?
    var arqControlTTLExpired: UInt64?
    var fecNegotiated: UInt64?
    var fecGroupsCreated: UInt64?
    var fecSymbolsSent: UInt64?
    var fecSymbolsReceived: UInt64?
    var fecDecodedGroups: UInt64?
    var fecRecoveredPackets: UInt64?
    var fecFailedGroups: UInt64?
    var fecOverheadBytes: UInt64?

    init(metrics: TunnelMetrics) {
        status = metrics.status
        phase = metrics.phase
        profileName = metrics.profileName
        tunnelProtocol = metrics.tunnelProtocol
        socksAddress = metrics.socksAddress
        startedAt = metrics.startedAt
        updatedAt = metrics.updatedAt
        uptimeSeconds = metrics.uptimeSeconds
        providerStartedAt = metrics.providerStartedAt
        providerHeartbeatAt = metrics.providerHeartbeatAt
        providerLastTelemetryWriteAt = metrics.providerLastTelemetryWriteAt
        providerStoppingAt = metrics.providerStoppingAt
        providerStoppedAt = metrics.providerStoppedAt
        providerStopReasonRaw = metrics.providerStopReasonRaw
        providerStopReasonName = metrics.providerStopReasonName
        providerLastLifecycleEvent = metrics.providerLastLifecycleEvent
        hevRunning = metrics.hevRunning
        hevExitCode = metrics.hevExitCode
        hevExitedAt = metrics.hevExitedAt
        packetBridgeExitedAt = metrics.packetBridgeExitedAt
        packetBridgeExitCode = metrics.packetBridgeExitCode
        memoryResidentBytes = metrics.memoryResidentBytes
        memoryPhysicalFootprintBytes = metrics.memoryPhysicalFootprintBytes
        threadCount = metrics.threadCount
        openFileDescriptorCount = metrics.openFileDescriptorCount
        resolverAddress = metrics.resolverAddress
        sessionID = metrics.sessionID
        uploadMTU = metrics.uploadMTU
        downloadMTU = metrics.downloadMTU
        acceptedResolvers = metrics.acceptedResolvers
        rejectedResolvers = metrics.rejectedResolvers
        sendsPerPacket = metrics.sendsPerPacket
        duplicateCopiesPerPacket = metrics.duplicateCopiesPerPacket
        uploadPackets = metrics.uploadPackets
        downloadPackets = metrics.downloadPackets
        uploadBytes = metrics.uploadBytes
        downloadBytes = metrics.downloadBytes
        totalBytes = metrics.totalBytes
        uploadBytesPerSecond = metrics.uploadBytesPerSecond
        downloadBytesPerSecond = metrics.downloadBytesPerSecond
        totalBytesPerSecond = metrics.totalBytesPerSecond
        bridgeInputPackets = metrics.bridgeInputPackets
        bridgeInputBytes = metrics.bridgeInputBytes
        bridgeOutputPackets = metrics.bridgeOutputPackets
        bridgeOutputBytes = metrics.bridgeOutputBytes
        firstBridgeInputAt = metrics.firstBridgeInputAt
        firstBridgeOutputAt = metrics.firstBridgeOutputAt
        bridgeReadErrors = metrics.bridgeReadErrors
        bridgeWriteErrors = metrics.bridgeWriteErrors
        bridgeShortWrites = metrics.bridgeShortWrites
        lastBridgeError = metrics.lastBridgeError
        engineRunning = metrics.engineRunning
        engineStartedAt = metrics.engineStartedAt
        engineLastError = metrics.engineLastError
        lastLogLine = metrics.lastLogLine
        lastError = metrics.lastError
        arqStreamsCreated = metrics.arqStreamsCreated
        arqStreamsClosed = metrics.arqStreamsClosed
        arqStreamsActive = metrics.arqStreamsActive
        arqDataPacketsRead = metrics.arqDataPacketsRead
        arqDataPacketsQueued = metrics.arqDataPacketsQueued
        arqDataPacketsQueueRejected = metrics.arqDataPacketsQueueRejected
        arqDataPacketsDequeued = metrics.arqDataPacketsDequeued
        arqDataPacketsAcked = metrics.arqDataPacketsAcked
        arqDataPacketsReceived = metrics.arqDataPacketsReceived
        arqDataAckPacketsSent = metrics.arqDataAckPacketsSent
        arqDataAckPacketsRejected = metrics.arqDataAckPacketsRejected
        arqDataNackPacketsSent = metrics.arqDataNackPacketsSent
        arqDataNackPacketsRejected = metrics.arqDataNackPacketsRejected
        arqDataNackPacketsReceived = metrics.arqDataNackPacketsReceived
        arqDataResendsQueued = metrics.arqDataResendsQueued
        arqDataResendsRejected = metrics.arqDataResendsRejected
        arqDataNackResendsQueued = metrics.arqDataNackResendsQueued
        arqDataNackResendsRejected = metrics.arqDataNackResendsRejected
        arqDataTimeoutResendsQueued = metrics.arqDataTimeoutResendsQueued
        arqDataTimeoutResendsRejected = metrics.arqDataTimeoutResendsRejected
        arqDataMaxRetriesExceeded = metrics.arqDataMaxRetriesExceeded
        arqDataTTLExpired = metrics.arqDataTTLExpired
        arqControlPacketsQueued = metrics.arqControlPacketsQueued
        arqControlPacketsQueueRejected = metrics.arqControlPacketsQueueRejected
        arqControlPacketsDequeued = metrics.arqControlPacketsDequeued
        arqControlPacketsAcked = metrics.arqControlPacketsAcked
        arqControlResendsQueued = metrics.arqControlResendsQueued
        arqControlResendsRejected = metrics.arqControlResendsRejected
        arqControlMaxRetriesExceeded = metrics.arqControlMaxRetriesExceeded
        arqControlTTLExpired = metrics.arqControlTTLExpired
        fecNegotiated = metrics.fecNegotiated
        fecGroupsCreated = metrics.fecGroupsCreated
        fecSymbolsSent = metrics.fecSymbolsSent
        fecSymbolsReceived = metrics.fecSymbolsReceived
        fecDecodedGroups = metrics.fecDecodedGroups
        fecRecoveredPackets = metrics.fecRecoveredPackets
        fecFailedGroups = metrics.fecFailedGroups
        fecOverheadBytes = metrics.fecOverheadBytes
    }
}
