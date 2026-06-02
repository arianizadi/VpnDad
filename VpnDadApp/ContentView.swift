import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var model = ProfileListModel()
    @StateObject private var vpn = VPNController()
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = ProfileDocument()
    @State private var exportName = "vpn-profile.json"

    var body: some View {
        NavigationView {
            List {
                ForEach(model.profiles) { profile in
                    NavigationLink {
                        ProfileDetailView(profile: profile, model: model, vpn: vpn)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(profile.name)
                                .font(.headline)
                            Text("\(profile.tunnelProtocol.rawValue)  \(profile.domain)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    offsets.map { model.profiles[$0] }.forEach(model.delete)
                }
            }
            .navigationTitle("VpnDad")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        importing = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .overlay {
                if model.profiles.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("No Profiles")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text(vpn.status.displayName)
                .foregroundStyle(.secondary)
        }
        .navigationViewStyle(.stack)
        .task {
            model.reload()
            await vpn.refresh()
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            model.importFile(result)
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportName
        ) { _ in }
        .alert("VPN", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

struct ProfileDetailView: View {
    let profile: VPNProfile
    @ObservedObject var model: ProfileListModel
    @ObservedObject var vpn: VPNController
    @StateObject private var health = HealthModel()
    @State private var connecting = false
    @State private var exporting = false
    @State private var exportDocument = ProfileDocument()
    @State private var diagnosticExporting = false
    @State private var diagnosticDocument = ProfileDocument()
    @State private var editingProfile = false

    private let healthProbeColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var currentProbe: HealthProbeSnapshot? {
        guard health.probeSnapshot?.profileID == profile.id else {
            return nil
        }
        return health.probeSnapshot
    }

    private var healthReport: TunnelHealthReport {
        TunnelHealthEvaluator.evaluate(
            profile: profile,
            vpnStatus: vpn.status,
            metrics: model.tunnelMetrics,
            probe: currentProbe,
            tunnelLog: model.tunnelLog
        )
    }

    var body: some View {
        Form {
            Section {
                InfoRow(title: "Status", value: vpn.status.displayName)
                InfoRow(title: "Protocol", value: profile.tunnelProtocol.rawValue)
                InfoRow(title: "Domain", value: profile.domain)
                InfoRow(title: "Resolvers", value: "\(profile.resolvers.count)")
                if let expectedExitIP = profile.expectedExitIP {
                    InfoRow(title: "Expected Exit", value: expectedExitIP)
                }
            }

            Section {
                Button {
                    Task {
                        await connect()
                    }
                } label: {
                    Label("Connect", systemImage: "power")
                }
                .disabled(connecting || vpn.status == .connected || vpn.status == .connecting)

                Button {
                    vpn.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "poweroff")
                }
                .disabled(vpn.status == .disconnected || vpn.status == .invalid)
            }

            Section("Health") {
                HealthSummaryView(report: healthReport)

                VStack(alignment: .leading, spacing: 10) {
                    LazyVGrid(columns: healthProbeColumns, alignment: .leading, spacing: 8) {
                        ForEach(HealthProbeKind.allCases) { kind in
                            Button {
                                Task {
                                    await runHealthCheck(kind)
                                }
                            } label: {
                                HealthProbeButtonLabel(
                                    kind: kind,
                                    isRunning: health.runningProbeKind == kind && health.isRunningChecks
                                )
                            }
                            .buttonStyle(.bordered)
                            .disabled(health.isRunningChecks)
                        }
                    }

                    Button {
                        Task {
                            await runAllHealthChecks()
                        }
                    } label: {
                        Label("Run All Checks", systemImage: "stethoscope")
                    }
                    .disabled(health.isRunningChecks)
                    .buttonStyle(.borderedProminent)

                    if health.isRunningChecks {
                        ProgressView()
                    } else if let probe = currentProbe {
                        Text("Checked \(relativeTime(probe.updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    exportDiagnosticBundle()
                } label: {
                    Label("Export Diagnostics", systemImage: "square.and.arrow.up.on.square")
                }

                if let probe = currentProbe {
                    HealthProbeResultsView(probe: probe)
                } else {
                    Text("No health checks yet")
                        .foregroundStyle(.secondary)
                }

                if let error = health.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                DisclosureGroup {
                    HealthTimelineView(events: healthReport.timeline)
                } label: {
                    Label("Connection Timeline", systemImage: "timeline.selection")
                }
            }

            Section("Live Metrics") {
                HStack {
                    Button {
                        model.reloadTunnelMetrics()
                    } label: {
                        Label("Refresh", systemImage: "gauge.with.dots.needle.50percent")
                    }

                    Spacer()

                    if let metrics = model.tunnelMetrics {
                        Text("Updated \(relativeTime(metrics.updatedAt))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let metrics = model.tunnelMetrics {
                    TunnelMetricsView(metrics: metrics)
                } else {
                    Text("No tunnel metrics yet")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Tunnel Log") {
                HStack {
                    Button {
                        model.reloadTunnelLog()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }

                    Spacer()

                    Button(role: .destructive) {
                        model.clearTunnelLog()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }

                if model.tunnelLog.isEmpty {
                    Text("No tunnel log yet")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(model.tunnelLog)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(minHeight: 120, maxHeight: 260)
                }
            }

            if let exportText = model.exportText(for: profile) {
                Section {
                    QRCodeView(text: exportText)
                        .frame(maxWidth: .infinity, minHeight: 220)

                    Button {
                        if let data = exportText.data(using: .utf8) {
                            exportDocument = ProfileDocument(data: data)
                            exporting = true
                        }
                    } label: {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .navigationTitle(profile.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    editingProfile = true
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(role: .destructive) {
                    model.delete(profile)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .sheet(isPresented: $editingProfile) {
            ProfileEditorView(profile: profile) { updated in
                model.update(updated)
            }
        }
        .fileExporter(
            isPresented: $exporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "\(profile.name)-vpn-profile.json"
        ) { _ in }
        .fileExporter(
            isPresented: $diagnosticExporting,
            document: diagnosticDocument,
            contentType: .json,
            defaultFilename: "\(profile.name)-diagnostics.json"
        ) { _ in }
        .onAppear {
            model.reloadTunnelLog()
            model.reloadTunnelMetrics()
            health.reload()
        }
        .task {
            while !Task.isCancelled {
                model.reloadTunnelMetrics()
                model.reloadTunnelLog()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task(id: "\(profile.id.uuidString)-\(vpn.status.rawValue)") {
            guard vpn.status == .connected else {
                health.resetAutomaticRun()
                return
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled {
                return
            }
            await health.runAutomaticIfNeeded(profile: profile, vpnStatus: vpn.status, metrics: model.tunnelMetrics)
            model.reloadTunnelLog()
        }
    }

    private func connect() async {
        connecting = true
        defer { connecting = false }
        do {
            try await vpn.connect(profile: profile)
            model.reloadTunnelLog()
        } catch {
            model.errorMessage = error.localizedDescription
            model.reloadTunnelLog()
        }
    }

    private func runHealthCheck(_ kind: HealthProbeKind) async {
        model.reloadTunnelMetrics()
        await health.runCheck(kind, profile: profile, vpnStatus: vpn.status, metrics: model.tunnelMetrics)
        model.reloadTunnelMetrics()
        model.reloadTunnelLog()
    }

    private func runAllHealthChecks() async {
        model.reloadTunnelMetrics()
        await health.runAllChecks(profile: profile, vpnStatus: vpn.status, metrics: model.tunnelMetrics)
        model.reloadTunnelMetrics()
        model.reloadTunnelLog()
    }

    private func exportDiagnosticBundle() {
        model.reloadTunnelMetrics()
        model.reloadTunnelLog()
        let report = TunnelHealthEvaluator.evaluate(
            profile: profile,
            vpnStatus: vpn.status,
            metrics: model.tunnelMetrics,
            probe: currentProbe,
            tunnelLog: model.tunnelLog
        )
        do {
            let data = try DiagnosticBundleBuilder.makeData(
                profile: profile,
                vpnStatus: vpn.status,
                metrics: model.tunnelMetrics,
                probe: currentProbe,
                report: report,
                tunnelLog: model.tunnelLog
            )
            diagnosticDocument = ProfileDocument(data: data)
            diagnosticExporting = true
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

struct ProfileEditorView: View {
    let profile: VPNProfile
    let onSave: (VPNProfile) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var domain: String
    @State private var resolverAddress: String
    @State private var expectedExitIP: String
    @State private var encryptionLevel: String
    @State private var fecLevel: String
    @State private var baseEncodeData: Bool
    @State private var replacementKey: String

    private let encryptionLevels = ["standard", "strong", "maximum"]
    private let fecLevels = ["none", "conservative", "balanced", "aggressive"]

    init(profile: VPNProfile, onSave: @escaping (VPNProfile) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _domain = State(initialValue: profile.domain)
        _resolverAddress = State(initialValue: profile.resolvers.first?.address ?? "")
        _expectedExitIP = State(initialValue: profile.expectedExitIP ?? "")
        let masterdns = profile.masterdns
        _encryptionLevel = State(initialValue: Self.encryptionLevel(for: masterdns))
        _fecLevel = State(initialValue: Self.fecLevel(for: masterdns))
        _baseEncodeData = State(initialValue: masterdns?.baseEncodeData ?? false)
        _replacementKey = State(initialValue: "")
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("Domain", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Resolver", text: $resolverAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    TextField("Expected Exit IP", text: $expectedExitIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }

                if profile.tunnelProtocol == .masterdns {
                    Section("MasterDNS") {
                        Picker("Encryption", selection: $encryptionLevel) {
                            ForEach(encryptionLevels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        Picker("FEC", selection: $fecLevel) {
                            ForEach(fecLevels, id: \.self) { level in
                                Text(level.capitalized).tag(level)
                            }
                        }
                        Toggle("Base Encode", isOn: $baseEncodeData)
                        SecureField("New Shared Key", text: $replacementKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
            }
            .navigationTitle("Edit Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(updatedProfile())
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              resolverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func updatedProfile() -> VPNProfile {
        var updated = profile
        updated.name = name
        updated.domain = domain
        updated.resolvers = [
            ResolverEndpoint(type: profile.resolvers.first?.type ?? "udp", address: resolverAddress)
        ]
        let trimmedExpectedExitIP = expectedExitIP.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.expectedExitIP = trimmedExpectedExitIP.isEmpty ? nil : trimmedExpectedExitIP

        if var settings = updated.masterdns {
            settings.encryptionLevel = encryptionLevel
            settings.encryptionMethod = MasterDNSSettings.encryptionMethod(forLevel: encryptionLevel) ?? settings.encryptionMethod
            settings.baseEncodeData = baseEncodeData
            settings.fecLevel = fecLevel
            let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                settings.encryptionKey = key
                settings.encryptionKeyRef = nil
            }
            updated.masterdns = settings
        }
        return updated.normalizedForStorage()
    }

    private static func encryptionLevel(for settings: MasterDNSSettings?) -> String {
        if let level = MasterDNSSettings.normalizedEncryptionLevel(settings?.encryptionLevel),
           MasterDNSSettings.encryptionMethod(forLevel: level) != nil {
            return level
        }
        switch settings?.encryptionMethod {
        case 3:
            return "standard"
        case 4:
            return "strong"
        default:
            return "maximum"
        }
    }

    private static func fecLevel(for settings: MasterDNSSettings?) -> String {
        if let level = MasterDNSSettings.normalizedFECLevel(settings?.fecLevel),
           MasterDNSSettings.fecSettings(forLevel: level) != nil {
            return level
        }
        guard settings?.fecEnabled == true else {
            return "none"
        }
        if settings?.fecGroupSize == 16 && settings?.fecOverheadPercent == 40 {
            return "aggressive"
        }
        if settings?.fecGroupSize == 12 && settings?.fecOverheadPercent == 25 {
            return "balanced"
        }
        return "conservative"
    }
}

struct HealthSummaryView: View {
    let report: TunnelHealthReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(report.verdict.displayName)
                    .font(.headline)
            } icon: {
                Image(systemName: report.verdict.systemImage)
            }
            .foregroundStyle(report.verdict.tint)

            Text(report.summary)
                .font(.subheadline)

            ForEach(Array(report.evidence.prefix(5).enumerated()), id: \.offset) { _, item in
                Label(item, systemImage: "smallcircle.filled.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct HealthProbeButtonLabel: View {
    let kind: HealthProbeKind
    let isRunning: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: kind.systemImage)
            }
            Text(kind.title)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    }
}

struct HealthProbeResultsView: View {
    let probe: HealthProbeSnapshot

    var body: some View {
        VStack(spacing: 8) {
            ProbeResultRow(title: "Public IP", check: probe.publicIP)
            ProbeResultRow(title: "DNS Leak", check: probe.dnsLeak)
            ProbeResultRow(title: "1.1.1.1/help", check: probe.directHTTPS)
            ProbeResultRow(title: "Resolver", check: probe.resolverReachability)
            ProbeResultRow(title: "Handshake", check: probe.tunnelHandshake)
            ProbeResultRow(title: "Hostname HTTPS", check: probe.hostnameHTTPS)
            if let observedIP = probe.observedExitIP {
                MetricRow(title: "Observed Exit", value: observedIP)
            }
            if let expectedIP = probe.expectedExitIP {
                MetricRow(
                    title: "Expected Exit",
                    value: probe.expectedExitIPMatched == true ? "\(expectedIP) matched" : "\(expectedIP) not matched"
                )
            }
            if !probe.reportedDNSServers.isEmpty {
                MetricRow(title: "Reported DNS", value: probe.reportedDNSServers.joined(separator: ", "))
            }
            if let expectedDNSServers = probe.expectedDNSServers, !expectedDNSServers.isEmpty {
                MetricRow(title: "Expected DNS", value: expectedDNSServers.joined(separator: ", "))
            }
        }
    }
}

struct ProbeResultRow: View {
    let title: String
    let check: HealthProbeCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Label(title, systemImage: check.status.systemImage)
                .foregroundStyle(check.status.tint)
            Spacer(minLength: 8)
            Text(detail)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .font(.caption)
    }

    private var detail: String {
        var parts = [check.status.displayName]
        if let duration = check.durationMilliseconds {
            parts.append("\(duration)ms")
        }
        if let statusCode = check.statusCode {
            parts.append("HTTP \(statusCode)")
        }
        parts.append(check.detail)
        return parts.joined(separator: " · ")
    }
}

struct HealthTimelineView: View {
    let events: [HealthTimelineEvent]

    var body: some View {
        if events.isEmpty {
            Text("No timeline events yet")
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { event in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: event.severity.systemImage)
                            .foregroundStyle(event.severity.tint)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.title)
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if let date = event.date {
                                    Text(relativeTime(date))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(event.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

struct TunnelMetricsView: View {
    let metrics: TunnelMetrics

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    private var arqDataResends: UInt64 {
        metrics.arqDataResendsQueued ?? 0
    }

    private var arqControlResends: UInt64 {
        metrics.arqControlResendsQueued ?? 0
    }

    private var arqTotalResends: UInt64 {
        arqDataResends + arqControlResends
    }

    private var arqTotalRejected: UInt64 {
        [
            metrics.arqDataPacketsQueueRejected,
            metrics.arqDataResendsRejected,
            metrics.arqDataNackPacketsRejected,
            metrics.arqDataAckPacketsRejected,
            metrics.arqControlPacketsQueueRejected,
            metrics.arqControlResendsRejected
        ].compactMap { $0 }.reduce(0, +)
    }

    private var arqTotalAcked: UInt64 {
        (metrics.arqDataPacketsAcked ?? 0) + (metrics.arqControlPacketsAcked ?? 0)
    }

    private var arqQueueEvents: UInt64 {
        (metrics.arqDataPacketsQueued ?? 0) +
            (metrics.arqDataResendsQueued ?? 0) +
            (metrics.arqControlPacketsQueued ?? 0) +
            (metrics.arqControlResendsQueued ?? 0)
    }

    private var arqResendRatio: String {
        guard arqQueueEvents > 0 else {
            return "n/a"
        }
        let ratio = Double(arqTotalResends) * 100 / Double(arqQueueEvents)
        return String(format: "%.1f%%", ratio)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                MetricTile(
                    title: "Upload",
                    value: formatBytes(metrics.uploadBytes),
                    detail: "\(formatRate(metrics.uploadBytesPerSecond))  \(metrics.uploadPackets) pkts",
                    systemImage: "arrow.up.circle"
                )
                MetricTile(
                    title: "Download",
                    value: formatBytes(metrics.downloadBytes),
                    detail: "\(formatRate(metrics.downloadBytesPerSecond))  \(metrics.downloadPackets) pkts",
                    systemImage: "arrow.down.circle"
                )
                MetricTile(
                    title: "Total",
                    value: formatBytes(metrics.totalBytes),
                    detail: "\(formatRate(metrics.totalBytesPerSecond)) combined",
                    systemImage: "sum"
                )
                MetricTile(
                    title: "Uptime",
                    value: formatDuration(metrics.uptimeSeconds),
                    detail: metrics.phase,
                    systemImage: "timer"
                )
                MetricTile(
                    title: "Configured Sends",
                    value: "\(metrics.sendsPerPacket ?? 1)x",
                    detail: "+\(metrics.duplicateCopiesPerPacket ?? 0) duplicate copy/packet",
                    systemImage: "repeat"
                )
                MetricTile(
                    title: "Bridge Errors",
                    value: "\(metrics.bridgeReadErrors + metrics.bridgeWriteErrors + metrics.bridgeShortWrites)",
                    detail: "read \(metrics.bridgeReadErrors)  write \(metrics.bridgeWriteErrors)  short \(metrics.bridgeShortWrites)",
                    systemImage: "exclamationmark.triangle"
                )
                MetricTile(
                    title: "ARQ Resends",
                    value: "\(arqTotalResends)",
                    detail: "data \(arqDataResends)  control \(arqControlResends)",
                    systemImage: "arrow.triangle.2.circlepath"
                )
                MetricTile(
                    title: "ARQ NACKs",
                    value: "\(metrics.arqDataNackPacketsReceived ?? 0) rx",
                    detail: "\(metrics.arqDataNackPacketsSent ?? 0) sent  \(metrics.arqDataNackResendsQueued ?? 0) resend queued",
                    systemImage: "arrow.uturn.backward.circle"
                )
                MetricTile(
                    title: "ARQ Streams",
                    value: "\(metrics.arqStreamsActive ?? 0) active",
                    detail: "\(metrics.arqStreamsCreated ?? 0) created  \(metrics.arqStreamsClosed ?? 0) closed",
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                MetricTile(
                    title: "ARQ Rejects",
                    value: "\(arqTotalRejected)",
                    detail: "queue rejects and send failures",
                    systemImage: "xmark.octagon"
                )
                MetricTile(
                    title: "FEC Recovery",
                    value: "\(metrics.fecRecoveredPackets ?? 0)",
                    detail: "\(metrics.fecDecodedGroups ?? 0) decoded groups  \(metrics.fecSymbolsReceived ?? 0) symbols rx",
                    systemImage: "lifepreserver"
                )
            }

            VStack(spacing: 8) {
                MetricRow(title: "Status", value: "\(metrics.status) / \(metrics.phase)")
                MetricRow(title: "Session", value: metrics.sessionID.map(String.init) ?? "n/a")
                MetricRow(title: "Resolver", value: metrics.resolverAddress ?? "n/a")
                MetricRow(title: "MTU", value: "up \(metrics.uploadMTU.map(String.init) ?? "n/a") / down \(metrics.downloadMTU.map(String.init) ?? "n/a")")
                MetricRow(title: "Resolvers", value: "accepted \(metrics.acceptedResolvers.map(String.init) ?? "n/a") / rejected \(metrics.rejectedResolvers.map(String.init) ?? "n/a")")
                MetricRow(title: "Traffic Source", value: "iOS packet-flow bridge counters")
                MetricRow(title: "Bridge Packets", value: "\(metrics.bridgeInputPackets) app->Hev / \(metrics.bridgeOutputPackets) Hev->app")
                MetricRow(title: "Bridge Bytes", value: "\(formatBytes(metrics.bridgeInputBytes)) app->Hev / \(formatBytes(metrics.bridgeOutputBytes)) Hev->app")
                MetricRow(title: "First Packet In", value: metrics.firstBridgeInputAt.map(relativeTime) ?? "n/a")
                MetricRow(title: "First Packet Out", value: metrics.firstBridgeOutputAt.map(relativeTime) ?? "n/a")
                MetricRow(title: "ARQ Resend Ratio", value: "\(arqResendRatio) = resends / queued ARQ packets")
                MetricRow(title: "ARQ Acked", value: "\(arqTotalAcked) total / \(metrics.arqDataPacketsAcked ?? 0) data / \(metrics.arqControlPacketsAcked ?? 0) control")
                MetricRow(title: "ARQ Data TX", value: "read \(metrics.arqDataPacketsRead ?? 0) / queued \(metrics.arqDataPacketsQueued ?? 0) / dequeued \(metrics.arqDataPacketsDequeued ?? 0)")
                MetricRow(title: "ARQ Data RX", value: "received \(metrics.arqDataPacketsReceived ?? 0) / ACK sent \(metrics.arqDataAckPacketsSent ?? 0) / ACK reject \(metrics.arqDataAckPacketsRejected ?? 0)")
                MetricRow(title: "ARQ Data Resend", value: "total \(arqDataResends) / timeout \(metrics.arqDataTimeoutResendsQueued ?? 0) / NACK \(metrics.arqDataNackResendsQueued ?? 0)")
                MetricRow(title: "ARQ Data Rejects", value: "data \(metrics.arqDataPacketsQueueRejected ?? 0) / resend \(metrics.arqDataResendsRejected ?? 0) / NACK \(metrics.arqDataNackPacketsRejected ?? 0)")
                MetricRow(title: "ARQ Control", value: "queued \(metrics.arqControlPacketsQueued ?? 0) / dequeued \(metrics.arqControlPacketsDequeued ?? 0) / acked \(metrics.arqControlPacketsAcked ?? 0)")
                MetricRow(title: "ARQ Control Resend", value: "queued \(arqControlResends) / rejected \(metrics.arqControlResendsRejected ?? 0)")
                MetricRow(title: "ARQ Expiry", value: "data max \(metrics.arqDataMaxRetriesExceeded ?? 0) ttl \(metrics.arqDataTTLExpired ?? 0) / control max \(metrics.arqControlMaxRetriesExceeded ?? 0) ttl \(metrics.arqControlTTLExpired ?? 0)")
                MetricRow(title: "FEC Negotiated", value: "\(metrics.fecNegotiated ?? 0)")
                MetricRow(title: "FEC Symbols", value: "sent \(metrics.fecSymbolsSent ?? 0) / received \(metrics.fecSymbolsReceived ?? 0) / overhead \(formatBytes(metrics.fecOverheadBytes ?? 0))")
                MetricRow(title: "FEC Groups", value: "created \(metrics.fecGroupsCreated ?? 0) / decoded \(metrics.fecDecodedGroups ?? 0) / failed \(metrics.fecFailedGroups ?? 0)")
                MetricRow(title: "Engine", value: metrics.engineRunning == true ? "running" : "not running")
                if let lastBridgeError = metrics.lastBridgeError {
                    MetricRow(title: "Bridge Error", value: lastBridgeError)
                }
                if let engineLastError = metrics.engineLastError {
                    MetricRow(title: "Engine Error", value: engineLastError)
                }
                if let lastError = metrics.lastError {
                    MetricRow(title: "Last Error", value: lastError)
                }
                if let lastLogLine = metrics.lastLogLine {
                    MetricRow(title: "Last Log", value: lastLogLine)
                }
            }

            DisclosureGroup {
                Text(metrics.engineStatusJSON)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Engine Status JSON", systemImage: "curlybraces")
            }
        }
    }
}

struct MetricTile: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct MetricRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.caption)
    }
}

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

private extension TunnelHealthVerdict {
    var tint: Color {
        switch self {
        case .disconnected:
            return .secondary
        case .starting, .waitingForTraffic:
            return .orange
        case .working:
            return .green
        case .degraded:
            return .yellow
        case .reconnectNeeded:
            return .red
        case .broken:
            return .red
        }
    }
}

private extension HealthProbeCheckStatus {
    var displayName: String {
        switch self {
        case .notRun:
            return "Not run"
        case .passed:
            return "Passed"
        case .warning:
            return "Review"
        case .failed:
            return "Failed"
        case .skipped:
            return "Skipped"
        }
    }

    var systemImage: String {
        switch self {
        case .notRun:
            return "circle"
        case .passed:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .failed:
            return "xmark.circle"
        case .skipped:
            return "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .notRun, .skipped:
            return .secondary
        case .passed:
            return .green
        case .warning:
            return .orange
        case .failed:
            return .red
        }
    }
}

private extension HealthTimelineSeverity {
    var systemImage: String {
        switch self {
        case .info:
            return "circle"
        case .success:
            return "checkmark.circle"
        case .warning:
            return "exclamationmark.triangle"
        case .failure:
            return "xmark.octagon"
        }
    }

    var tint: Color {
        switch self {
        case .info:
            return .secondary
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        }
    }
}

@MainActor
final class ProfileListModel: ObservableObject {
    @Published var profiles: [VPNProfile] = []
    @Published var errorMessage: String?
    @Published var tunnelLog = ""
    @Published var tunnelMetrics: TunnelMetrics?

    private let repository = ProfileRepository()

    func reload() {
        do {
            profiles = try repository.loadProfiles()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importFile(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let data = try Data(contentsOf: url)
            _ = try repository.importProfile(from: data)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func delete(_ profile: VPNProfile) {
        do {
            try repository.deleteProfile(profile)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func update(_ profile: VPNProfile) {
        do {
            _ = try repository.updateProfile(profile)
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportText(for profile: VPNProfile) -> String? {
        do {
            return String(data: try repository.profileJSONData(profile), encoding: .utf8)
        } catch {
            return nil
        }
    }

    func reloadTunnelLog() {
        do {
            tunnelLog = try repository.readTunnelLog()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reloadTunnelMetrics() {
        do {
            tunnelMetrics = try repository.readTunnelMetrics()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearTunnelLog() {
        do {
            try repository.clearTunnelLog()
            tunnelLog = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private func formatBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}

private func formatRate(_ bytesPerSecond: Double) -> String {
    "\(formatBytes(UInt64(max(0, bytesPerSecond))))/s"
}

private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    if hours > 0 {
        return "\(hours)h \(minutes)m"
    }
    if minutes > 0 {
        return "\(minutes)m \(secs)s"
    }
    return "\(secs)s"
}

private func relativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 2 {
        return "now"
    }
    return "\(seconds)s ago"
}

struct QRCodeView: View {
    let text: String
    private let context = CIContext()
    private let filter = CIFilter.qrCodeGenerator()

    var body: some View {
        if let image = makeImage() {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding()
        }
    }

    private func makeImage() -> UIImage? {
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return nil
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
