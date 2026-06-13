import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct ContentView: View {
    @StateObject private var model = ProfileListModel()
    @StateObject private var vpn = VPNController()
    @AppStorage(AppConstants.advancedModeDefaultsKey) private var advancedMode = false
    @State private var importing = false
    @State private var exporting = false
    @State private var exportDocument = ProfileDocument()
    @State private var exportName = "vpn-profile.json"

    private var statusColor: Color {
        switch vpn.status {
        case .connected:
            return .green
        case .connecting, .reasserting, .disconnecting:
            return .orange
        case .disconnected, .invalid:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 12, height: 12)
                        Text(vpn.status.displayName)
                            .font(.headline)
                        Spacer()
                        if vpn.status == .connected || vpn.status == .connecting {
                            Button("Disconnect", role: .destructive) {
                                vpn.disconnect()
                            }
                            .font(.subheadline)
                        }
                    }
                    .padding(.vertical, 2)
                }

                Section {
                    ForEach(model.profiles) { profile in
                        NavigationLink {
                            ProfileDetailView(profile: profile, model: model, vpn: vpn)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(.headline)
                                if advancedMode {
                                    Text("\(profile.tunnelProtocol.rawValue)  \(profile.domain)")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        offsets.map { model.profiles[$0] }.forEach(model.delete)
                    }
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
                    Menu {
                        Toggle(isOn: $advancedMode) {
                            Label("Advanced Mode", systemImage: "wrench.and.screwdriver")
                        }
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
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
    @AppStorage(AppConstants.advancedModeDefaultsKey) private var advancedMode = false
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

    private var connectDisabled: Bool {
        connecting || vpn.status == .connected || vpn.status == .connecting
    }

    var body: some View {
        Form {
            connectionSection

            healthSection

            if vpn.status == .connected, !advancedMode {
                simpleActivitySection
            }

            if advancedMode {
                profileInfoSection
                liveMetricsSection
                tunnelLogSection
                exportSection
            }
        }
        .navigationTitle(profile.name)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Toggle(isOn: $advancedMode) {
                        Label("Advanced Mode", systemImage: "wrench.and.screwdriver")
                    }
                    if advancedMode {
                        Button {
                            editingProfile = true
                        } label: {
                            Label("Edit", systemImage: "slider.horizontal.3")
                        }
                        Button(role: .destructive) {
                            model.delete(profile)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
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

    private var statusColor: Color {
        switch vpn.status {
        case .connected:
            return .green
        case .connecting, .reasserting, .disconnecting:
            return .orange
        case .disconnected, .invalid:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var isTunnelActive: Bool {
        vpn.status == .connected || vpn.status == .connecting || vpn.status == .reasserting
    }

    private var connectionSection: some View {
        Section {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                Text(vpn.status.displayName)
                    .font(.headline)
                Spacer()
                if vpn.status == .connected, let metrics = model.tunnelMetrics {
                    Text(formatDuration(metrics.uptimeSeconds))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)

            if isTunnelActive {
                Button(role: .destructive) {
                    vpn.disconnect()
                } label: {
                    Label("Disconnect", systemImage: "poweroff")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .disabled(vpn.status == .disconnecting)
            } else {
                Button {
                    Task {
                        await connect()
                    }
                } label: {
                    if connecting {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 36)
                    } else {
                        Label("Connect", systemImage: "power")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 36)
                    }
                }
                .disabled(connectDisabled)
            }
        }
    }

    private var healthSection: some View {
        Section("Health") {
            HealthSummaryView(report: healthReport, maxEvidence: advancedMode ? 5 : 2)

            Button {
                Task {
                    await runAllHealthChecks()
                }
            } label: {
                HStack {
                    Label("Check Connection", systemImage: "stethoscope")
                    Spacer()
                    if health.isRunningChecks {
                        ProgressView()
                            .controlSize(.small)
                    } else if let probe = currentProbe {
                        Text(L10n.string("Checked %@", relativeTime(probe.updatedAt)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .disabled(health.isRunningChecks)

            Button {
                exportDiagnosticBundle()
            } label: {
                Label("Export Diagnostics", systemImage: "square.and.arrow.up.on.square")
            }

            if let error = health.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if advancedMode {
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

                if let probe = currentProbe {
                    HealthProbeResultsView(probe: probe)
                } else {
                    Text("No health checks yet")
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup {
                    HealthTimelineView(events: healthReport.timeline)
                } label: {
                    Label("Connection Timeline", systemImage: "timeline.selection")
                }
            }
        }
    }

    private var simpleActivitySection: some View {
        Section("Connection") {
            if let metrics = model.tunnelMetrics {
                HStack(spacing: 8) {
                    MetricTile(
                        title: "Download",
                        value: formatRate(metrics.downloadBytesPerSecond),
                        detail: formatBytes(metrics.downloadBytes),
                        systemImage: "arrow.down.circle"
                    )
                    MetricTile(
                        title: "Upload",
                        value: formatRate(metrics.uploadBytesPerSecond),
                        detail: formatBytes(metrics.uploadBytes),
                        systemImage: "arrow.up.circle"
                    )
                }
            } else {
                Text("No tunnel metrics yet")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var profileInfoSection: some View {
        Section("Profile") {
            InfoRow(title: "Protocol", value: profile.tunnelProtocol.rawValue)
            if profile.tunnelProtocol == .masterdns {
                InfoRow(title: "Runtime", value: profile.masterdns?.runtimeMode.displayName ?? MasterDNSRuntimeMode.hevSocks.displayName)
            }
            InfoRow(title: "Domain", value: profile.domain)
            InfoRow(title: "Resolvers", value: "\(profile.resolvers.count)")
            if let expectedExitIP = profile.expectedExitIP {
                InfoRow(title: "Expected Exit", value: expectedExitIP)
            }
        }
    }

    private var liveMetricsSection: some View {
        Section("Live Metrics") {
            HStack {
                Button {
                    model.reloadTunnelMetrics()
                } label: {
                    Label("Refresh", systemImage: "gauge.with.dots.needle.50percent")
                }

                Spacer()

                if let metrics = model.tunnelMetrics {
                    Text(L10n.string("Updated %@", relativeTime(metrics.updatedAt)))
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
    }

    private var tunnelLogSection: some View {
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
    }

    @ViewBuilder
    private var exportSection: some View {
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
    @State private var domainLines: String
    @State private var resolverAddress: String
    @State private var masterDNSResolverAddresses: String
    @State private var expectedExitIP: String
    @State private var runtimeMode: MasterDNSRuntimeMode
    @State private var protocolType: String
    @State private var localDNSEnabled: Bool
    @State private var encryptionLevel: String
    @State private var encryptionMethod: String
    @State private var fecLevel: String
    @State private var baseEncodeData: Bool
    @State private var uploadCompressionType: String
    @State private var downloadCompressionType: String
    @State private var compressionMinSize: String
    @State private var minUploadMTU: String
    @State private var maxUploadMTU: String
    @State private var minDownloadMTU: String
    @State private var maxDownloadMTU: String
    @State private var resolverStrategy: String
    @State private var packetDuplicationCount: String
    @State private var setupPacketDuplicationCount: String
    @State private var rxWorkers: String
    @State private var tunnelProcessWorkers: String
    @State private var maxPacketsPerBatch: String
    @State private var tunnelPacketTimeout: String
    @State private var arqWindowSize: String
    @State private var arqInitialRTO: String
    @State private var arqMaxRTO: String
    @State private var arqMaxDataRetries: String
    @State private var logLevel: String
    @State private var fecGroupSize: String
    @State private var fecOverheadPercent: String
    @State private var fecSymbolSize: String
    @State private var fecFlushTimeoutMs: String
    @State private var replacementKey: String
    @State private var showExperimentalFEC: Bool

    private let encryptionLevels = ["custom", "standard", "strong", "maximum"]
    private let fecLevels = ["none", "conservative", "balanced", "aggressive"]
    private let protocolTypes = ["SOCKS5", "TCP"]
    private let logLevels = ["DEBUG", "INFO", "WARN", "ERROR"]

    init(profile: VPNProfile, onSave: @escaping (VPNProfile) -> Void) {
        self.profile = profile
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _domain = State(initialValue: profile.domain)
        _domainLines = State(initialValue: Self.domainLines(for: profile))
        _resolverAddress = State(initialValue: profile.resolvers.first?.address ?? "")
        _masterDNSResolverAddresses = State(initialValue: Self.resolverLines(for: profile.resolvers))
        _expectedExitIP = State(initialValue: profile.expectedExitIP ?? "")
        let masterdns = profile.masterdns
        let config = masterdns?.clientConfig ?? [:]
        let initialRuntime = masterdns?.runtimeMode ?? .hevSocks
        _runtimeMode = State(initialValue: initialRuntime)
        _protocolType = State(initialValue: initialRuntime == .nativePacket ? "TCP" : (config["PROTOCOL_TYPE"]?.stringValue?.uppercased() ?? "SOCKS5"))
        _localDNSEnabled = State(initialValue: initialRuntime == .nativePacket ? true : (config["LOCAL_DNS_ENABLED"]?.boolValue ?? false))
        _encryptionLevel = State(initialValue: Self.encryptionLevel(for: masterdns))
        _encryptionMethod = State(initialValue: Self.configIntString(config, "DATA_ENCRYPTION_METHOD", fallback: masterdns?.encryptionMethod ?? 5))
        _fecLevel = State(initialValue: Self.fecLevel(for: masterdns))
        _baseEncodeData = State(initialValue: masterdns?.baseEncodeData ?? false)
        _uploadCompressionType = State(initialValue: Self.configIntString(config, "UPLOAD_COMPRESSION_TYPE", fallback: 0))
        _downloadCompressionType = State(initialValue: Self.configIntString(config, "DOWNLOAD_COMPRESSION_TYPE", fallback: 0))
        _compressionMinSize = State(initialValue: Self.configIntString(config, "COMPRESSION_MIN_SIZE", fallback: 128))
        _minUploadMTU = State(initialValue: Self.configIntString(config, "MIN_UPLOAD_MTU", fallback: 38))
        _maxUploadMTU = State(initialValue: Self.configIntString(config, "MAX_UPLOAD_MTU", fallback: 150))
        _minDownloadMTU = State(initialValue: Self.configIntString(config, "MIN_DOWNLOAD_MTU", fallback: 100))
        _maxDownloadMTU = State(initialValue: Self.configIntString(config, "MAX_DOWNLOAD_MTU", fallback: 500))
        _resolverStrategy = State(initialValue: Self.configIntString(config, "RESOLVER_BALANCING_STRATEGY", fallback: 2))
        _packetDuplicationCount = State(initialValue: Self.configIntString(config, "PACKET_DUPLICATION_COUNT", fallback: 1))
        _setupPacketDuplicationCount = State(initialValue: Self.configIntString(config, "SETUP_PACKET_DUPLICATION_COUNT", fallback: 1))
        _rxWorkers = State(initialValue: Self.configIntString(config, "RX_TX_WORKERS", fallback: 4))
        _tunnelProcessWorkers = State(initialValue: Self.configIntString(config, "TUNNEL_PROCESS_WORKERS", fallback: 0))
        _maxPacketsPerBatch = State(initialValue: Self.configIntString(config, "MAX_PACKETS_PER_BATCH", fallback: 8))
        _tunnelPacketTimeout = State(initialValue: Self.configDoubleString(config, "TUNNEL_PACKET_TIMEOUT_SECONDS", fallback: 10.0))
        _arqWindowSize = State(initialValue: Self.configIntString(config, "ARQ_WINDOW_SIZE", fallback: 600))
        _arqInitialRTO = State(initialValue: Self.configDoubleString(config, "ARQ_INITIAL_RTO_SECONDS", fallback: 0.5))
        _arqMaxRTO = State(initialValue: Self.configDoubleString(config, "ARQ_MAX_RTO_SECONDS", fallback: 3.0))
        _arqMaxDataRetries = State(initialValue: Self.configIntString(config, "ARQ_MAX_DATA_RETRIES", fallback: 128))
        _logLevel = State(initialValue: config["LOG_LEVEL"]?.stringValue?.uppercased() ?? "INFO")
        _fecGroupSize = State(initialValue: Self.configIntString(config, "FEC_GROUP_SIZE", fallback: masterdns?.fecGroupSize ?? 8))
        _fecOverheadPercent = State(initialValue: Self.configIntString(config, "FEC_OVERHEAD_PERCENT", fallback: masterdns?.fecOverheadPercent ?? 15))
        _fecSymbolSize = State(initialValue: Self.configIntString(config, "FEC_SYMBOL_SIZE", fallback: masterdns?.fecSymbolSize ?? 0))
        _fecFlushTimeoutMs = State(initialValue: Self.configIntString(config, "FEC_FLUSH_TIMEOUT_MS", fallback: masterdns?.fecFlushTimeoutMs ?? 25))
        _replacementKey = State(initialValue: "")
        _showExperimentalFEC = State(initialValue: false)
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Profile") {
                    TextField("Name", text: $name)
                    TextField("Domain", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if profile.tunnelProtocol == .vaydns {
                        TextField("Resolver", text: $resolverAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }
                    TextField("Expected Exit IP", text: $expectedExitIP)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                }

                if profile.tunnelProtocol == .masterdns {
                    Section("Connection Mode") {
                        Picker("Runtime", selection: $runtimeMode) {
                            Text(MasterDNSRuntimeMode.nativePacket.displayName)
                                .tag(MasterDNSRuntimeMode.nativePacket)
                            Text(MasterDNSRuntimeMode.hevSocks.displayName).tag(MasterDNSRuntimeMode.hevSocks)
                        }
                        Picker("Protocol Type", selection: $protocolType) {
                            ForEach(protocolTypes, id: \.self) { value in
                                Text(value).tag(value)
                            }
                        }
                        .disabled(runtimeMode == .nativePacket)
                        if runtimeMode == .nativePacket {
                            Label("Native Packet is recommended for iOS upload stability and carries TCP plus DNS.", systemImage: "checkmark.shield")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if runtimeMode == .hevSocks && protocolType != "SOCKS5" {
                            Label("Hev SOCKS mode requires SOCKS5", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if runtimeMode == .hevSocks {
                            Label("Hev SOCKS is a legacy fallback and can disconnect during upload bursts.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Domains") {
                        TextEditor(text: $domainLines)
                            .font(.body.monospaced())
                            .frame(minHeight: 86)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    Section("MasterDNS UDP Resolvers") {
                        TextEditor(text: $masterDNSResolverAddresses)
                            .font(.body.monospaced())
                            .frame(minHeight: 92)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation)
                    }

                    Section("Encryption") {
                        Picker("Encryption", selection: $encryptionLevel) {
                            ForEach(encryptionLevels, id: \.self) { level in
                                Text(L10n.string(level.capitalized)).tag(level)
                            }
                        }
                        TextField("Encryption Method", text: $encryptionMethod)
                            .keyboardType(.numberPad)
                        Toggle("Base Encode", isOn: $baseEncodeData)
                        SecureField("New Shared Key", text: $replacementKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if (Int(encryptionMethod) ?? 5) < 3 {
                            Label("Legacy encryption method", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("DNS Cache") {
                        Toggle("Local DNS", isOn: $localDNSEnabled)
                            .disabled(runtimeMode == .hevSocks)
                        if runtimeMode == .hevSocks && localDNSEnabled {
                            Label("Hev SOCKS mode cannot use Local DNS", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Compression") {
                        TextField("Upload Compression", text: $uploadCompressionType)
                            .keyboardType(.numberPad)
                        TextField("Download Compression", text: $downloadCompressionType)
                            .keyboardType(.numberPad)
                        TextField("Compression Min Size", text: $compressionMinSize)
                            .keyboardType(.numberPad)
                    }

                    Section("MTU") {
                        TextField("Min Upload MTU", text: $minUploadMTU)
                            .keyboardType(.numberPad)
                        TextField("Max Upload MTU", text: $maxUploadMTU)
                            .keyboardType(.numberPad)
                        TextField("Min Download MTU", text: $minDownloadMTU)
                            .keyboardType(.numberPad)
                        TextField("Max Download MTU", text: $maxDownloadMTU)
                            .keyboardType(.numberPad)
                    }

                    Section("Resolver Strategy") {
                        TextField("Balancing Strategy", text: $resolverStrategy)
                            .keyboardType(.numberPad)
                        TextField("Packet Duplication", text: $packetDuplicationCount)
                            .keyboardType(.numberPad)
                        TextField("Setup Duplication", text: $setupPacketDuplicationCount)
                            .keyboardType(.numberPad)
                        if (Int(packetDuplicationCount) ?? 1) > 1 || (Int(setupPacketDuplicationCount) ?? 1) > 1 {
                            Label("Packet duplication increases upload pressure in iOS Hev mode.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }

                    Section("Workers and Timers") {
                        TextField("RX TX Workers", text: $rxWorkers)
                            .keyboardType(.numberPad)
                        TextField("Tunnel Workers", text: $tunnelProcessWorkers)
                            .keyboardType(.numberPad)
                        TextField("Max Batch", text: $maxPacketsPerBatch)
                            .keyboardType(.numberPad)
                        TextField("Packet Timeout", text: $tunnelPacketTimeout)
                            .keyboardType(.decimalPad)
                    }

                    Section("ARQ") {
                        TextField("Window Size", text: $arqWindowSize)
                            .keyboardType(.numberPad)
                        TextField("Initial RTO", text: $arqInitialRTO)
                            .keyboardType(.decimalPad)
                        TextField("Max RTO", text: $arqMaxRTO)
                            .keyboardType(.decimalPad)
                        TextField("Max Data Retries", text: $arqMaxDataRetries)
                            .keyboardType(.numberPad)
                    }

                    Section("Logging") {
                        Picker("Log Level", selection: $logLevel) {
                            ForEach(logLevels, id: \.self) { value in
                                Text(value).tag(value)
                            }
                        }
                    }

                    Section {
                        DisclosureGroup(isExpanded: $showExperimentalFEC) {
                            Text("FEC is experimental and custom-fork-only. Leave it off unless you are intentionally testing the custom MasterDnsVPN fork.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Picker("FEC", selection: $fecLevel) {
                                ForEach(fecLevels, id: \.self) { level in
                                    Text(L10n.string(level.capitalized)).tag(level)
                                }
                            }
                            TextField("Group Size", text: $fecGroupSize)
                                .keyboardType(.numberPad)
                            TextField("Overhead Percent", text: $fecOverheadPercent)
                                .keyboardType(.numberPad)
                            TextField("Symbol Size", text: $fecSymbolSize)
                                .keyboardType(.numberPad)
                            TextField("Flush Timeout Ms", text: $fecFlushTimeoutMs)
                                .keyboardType(.numberPad)
                        } label: {
                            Label("Experimental FEC", systemImage: "exclamationmark.triangle")
                        }
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
                    .disabled(saveDisabled)
                }
            }
            .onChange(of: runtimeMode) { newMode in
                if newMode == .hevSocks {
                    protocolType = "SOCKS5"
                    localDNSEnabled = false
                } else {
                    protocolType = "TCP"
                    localDNSEnabled = true
                }
            }
        }
    }

    private var saveDisabled: Bool {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        switch profile.tunnelProtocol {
        case .masterdns:
            return (runtimeMode == .hevSocks && protocolType != "SOCKS5") ||
                Self.masterDNSResolverEndpoints(from: masterDNSResolverAddresses).isEmpty ||
                Self.domainList(from: domainLines, fallback: domain).isEmpty
        case .vaydns:
            return resolverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func updatedProfile() -> VPNProfile {
        var updated = profile
        updated.name = name
        updated.domain = domain
        if profile.tunnelProtocol == .masterdns {
            let domains = Self.domainList(from: domainLines, fallback: domain)
            updated.domains = domains
            updated.domain = domains.first ?? domain
            updated.resolvers = Self.masterDNSResolverEndpoints(from: masterDNSResolverAddresses)
        } else {
            updated.resolvers = [
                ResolverEndpoint(type: profile.resolvers.first?.type ?? "udp", address: resolverAddress)
            ]
        }
        let trimmedExpectedExitIP = expectedExitIP.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.expectedExitIP = trimmedExpectedExitIP.isEmpty ? nil : trimmedExpectedExitIP

        if var settings = updated.masterdns {
            settings.runtimeMode = runtimeMode
            let selectedProtocolType = runtimeMode == .nativePacket ? "TCP" : protocolType
            let selectedLocalDNSEnabled = runtimeMode == .nativePacket ? true : localDNSEnabled
            if encryptionLevel == "custom" {
                settings.encryptionLevel = nil
                settings.encryptionMethod = Int(encryptionMethod) ?? settings.encryptionMethod
            } else {
                settings.encryptionLevel = encryptionLevel
                settings.encryptionMethod = MasterDNSSettings.encryptionMethod(forLevel: encryptionLevel) ?? settings.encryptionMethod
            }
            settings.baseEncodeData = baseEncodeData
            settings.clientConfig["DOMAINS"] = .array(updated.domains.map { .string($0) })
            settings.clientConfig["PROTOCOL_TYPE"] = .string(selectedProtocolType)
            settings.clientConfig["LOCAL_DNS_ENABLED"] = .bool(selectedLocalDNSEnabled)
            settings.clientConfig[VPNProfile.iosForceHevSocksClientConfigKey] = .bool(runtimeMode == .hevSocks)
            settings.clientConfig["DATA_ENCRYPTION_METHOD"] = .int(settings.encryptionMethod)
            settings.clientConfig["BASE_ENCODE_DATA"] = .bool(baseEncodeData)
            setIntConfig(&settings.clientConfig, "UPLOAD_COMPRESSION_TYPE", uploadCompressionType)
            setIntConfig(&settings.clientConfig, "DOWNLOAD_COMPRESSION_TYPE", downloadCompressionType)
            setIntConfig(&settings.clientConfig, "COMPRESSION_MIN_SIZE", compressionMinSize)
            setIntConfig(&settings.clientConfig, "MIN_UPLOAD_MTU", minUploadMTU)
            setIntConfig(&settings.clientConfig, "MAX_UPLOAD_MTU", maxUploadMTU)
            setIntConfig(&settings.clientConfig, "MIN_DOWNLOAD_MTU", minDownloadMTU)
            setIntConfig(&settings.clientConfig, "MAX_DOWNLOAD_MTU", maxDownloadMTU)
            setIntConfig(&settings.clientConfig, "RESOLVER_BALANCING_STRATEGY", resolverStrategy)
            setIntConfig(&settings.clientConfig, "PACKET_DUPLICATION_COUNT", packetDuplicationCount)
            setIntConfig(&settings.clientConfig, "SETUP_PACKET_DUPLICATION_COUNT", setupPacketDuplicationCount)
            setIntConfig(&settings.clientConfig, "RX_TX_WORKERS", rxWorkers)
            setIntConfig(&settings.clientConfig, "TUNNEL_PROCESS_WORKERS", tunnelProcessWorkers)
            setIntConfig(&settings.clientConfig, "MAX_PACKETS_PER_BATCH", maxPacketsPerBatch)
            setDoubleConfig(&settings.clientConfig, "TUNNEL_PACKET_TIMEOUT_SECONDS", tunnelPacketTimeout)
            setIntConfig(&settings.clientConfig, "ARQ_WINDOW_SIZE", arqWindowSize)
            setDoubleConfig(&settings.clientConfig, "ARQ_INITIAL_RTO_SECONDS", arqInitialRTO)
            setDoubleConfig(&settings.clientConfig, "ARQ_MAX_RTO_SECONDS", arqMaxRTO)
            setIntConfig(&settings.clientConfig, "ARQ_MAX_DATA_RETRIES", arqMaxDataRetries)
            settings.clientConfig["LOG_LEVEL"] = .string(logLevel)
            if showExperimentalFEC {
                settings.fecLevel = fecLevel
                settings.clientConfig["FEC_LEVEL"] = .string(fecLevel)
                setIntConfig(&settings.clientConfig, "FEC_GROUP_SIZE", fecGroupSize)
                setIntConfig(&settings.clientConfig, "FEC_OVERHEAD_PERCENT", fecOverheadPercent)
                setIntConfig(&settings.clientConfig, "FEC_SYMBOL_SIZE", fecSymbolSize)
                setIntConfig(&settings.clientConfig, "FEC_FLUSH_TIMEOUT_MS", fecFlushTimeoutMs)
            }
            let key = replacementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty {
                settings.encryptionKey = key
                settings.encryptionKeyRef = nil
            }
            updated.masterdns = settings
        }
        return updated.normalizedForStorage()
    }

    private static func domainLines(for profile: VPNProfile) -> String {
        let domains = profile.domains.isEmpty ? [profile.domain] : profile.domains
        return VPNProfile.normalizedDomains(domains).joined(separator: "\n")
    }

    private static func domainList(from text: String, fallback: String) -> [String] {
        let values = text.components(separatedBy: .newlines)
        let domains = VPNProfile.normalizedDomains(values)
        if !domains.isEmpty {
            return domains
        }
        return VPNProfile.normalizedDomains([fallback])
    }

    private static func resolverLines(for resolvers: [ResolverEndpoint]) -> String {
        resolvers.map(\.address).joined(separator: "\n")
    }

    private static func masterDNSResolverEndpoints(from text: String) -> [ResolverEndpoint] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { ResolverEndpoint(type: "udp", address: $0) }
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
        case 5, nil:
            return "maximum"
        default:
            return "custom"
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

    private static func configIntString(
        _ config: [String: ProfileJSONValue],
        _ key: String,
        fallback: Int
    ) -> String {
        "\(config[key]?.intValue ?? fallback)"
    }

    private static func configDoubleString(
        _ config: [String: ProfileJSONValue],
        _ key: String,
        fallback: Double
    ) -> String {
        let value = config[key]?.doubleValue ?? fallback
        if value.rounded() == value {
            return "\(Int(value))"
        }
        return "\(value)"
    }

    private func setIntConfig(
        _ config: inout [String: ProfileJSONValue],
        _ key: String,
        _ text: String
    ) {
        if let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            config[key] = .int(value)
        }
    }

    private func setDoubleConfig(
        _ config: inout [String: ProfileJSONValue],
        _ key: String,
        _ text: String
    ) {
        if let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            config[key] = .double(value)
        }
    }
}

struct HealthSummaryView: View {
    let report: TunnelHealthReport
    var maxEvidence = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(report.verdict.displayName)
                    .font(.headline)
            } icon: {
                Image(systemName: report.verdict.systemImage)
            }
            .foregroundStyle(report.verdict.tint)

            Text(L10n.string(report.summary))
                .font(.subheadline)

            ForEach(Array(report.evidence.prefix(maxEvidence).enumerated()), id: \.offset) { _, item in
                Label(L10n.string(item), systemImage: "smallcircle.filled.circle")
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
                    value: probe.expectedExitIPMatched == true
                        ? L10n.string("%@ matched", expectedIP)
                        : L10n.string("%@ not matched", expectedIP)
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
            Label(L10n.string(title), systemImage: check.status.systemImage)
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
        parts.append(L10n.string(check.detail))
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
                                Text(L10n.string(event.title))
                                    .font(.caption.weight(.semibold))
                                Spacer()
                                if let date = event.date {
                                    Text(relativeTime(date))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Text(L10n.string(event.detail))
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

    private var arqQueueRejected: UInt64 {
        [
            metrics.arqDataPacketsQueueRejected,
            metrics.arqDataResendsRejected,
            metrics.arqDataNackPacketsRejected,
            metrics.arqControlPacketsQueueRejected,
            metrics.arqControlResendsRejected
        ].compactMap { $0 }.reduce(0, +)
    }

    private var arqAckRejected: UInt64 {
        metrics.arqDataAckPacketsRejected ?? 0
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
            return L10n.string("n/a")
        }
        let ratio = Double(arqTotalResends) * 100 / Double(arqQueueEvents)
        return String(format: "%.1f%%", ratio)
    }

    private var providerHeartbeatAge: String {
        guard let heartbeatAt = metrics.providerHeartbeatAt else {
            return L10n.string("n/a")
        }
        return relativeTime(heartbeatAt)
    }

    private var providerResourceSummary: String {
        [
            metrics.memoryResidentBytes.map { "rss \(formatBytes($0))" },
            metrics.memoryPhysicalFootprintBytes.map { "footprint \(formatBytes($0))" },
            metrics.threadCount.map { "threads \($0)" },
            metrics.openFileDescriptorCount.map { "fds \($0)" }
        ].compactMap { $0 }.joined(separator: "  ")
    }

    private var runtimeDisplayName: String {
        switch metrics.runtimeMode {
        case MasterDNSRuntimeMode.nativePacket.rawValue:
            return MasterDNSRuntimeMode.nativePacket.displayName
        case MasterDNSRuntimeMode.hevSocks.rawValue:
            return MasterDNSRuntimeMode.hevSocks.displayName
        default:
            return L10n.string("Unknown")
        }
    }

    private var providerStateValue: String {
        if metrics.runtimeMode == MasterDNSRuntimeMode.nativePacket.rawValue {
            return runtimeDisplayName
        }
        return metrics.hevRunning == true ? L10n.string("HEV running") : L10n.string("HEV stopped")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                MetricTile(
                    title: "Upload",
                    value: formatBytes(metrics.uploadBytes),
                    detail: L10n.string("%@  %@ pkts", formatRate(metrics.uploadBytesPerSecond), "\(metrics.uploadPackets)"),
                    systemImage: "arrow.up.circle"
                )
                MetricTile(
                    title: "Download",
                    value: formatBytes(metrics.downloadBytes),
                    detail: L10n.string("%@  %@ pkts", formatRate(metrics.downloadBytesPerSecond), "\(metrics.downloadPackets)"),
                    systemImage: "arrow.down.circle"
                )
                MetricTile(
                    title: "Total",
                    value: formatBytes(metrics.totalBytes),
                    detail: L10n.string("%@ combined", formatRate(metrics.totalBytesPerSecond)),
                    systemImage: "sum"
                )
                MetricTile(
                    title: "Uptime",
                    value: formatDuration(metrics.uptimeSeconds),
                    detail: metrics.phase,
                    systemImage: "timer"
                )
                MetricTile(
                    title: "Provider",
                    value: providerStateValue,
                    detail: L10n.string("heartbeat %@", providerHeartbeatAge),
                    systemImage: "waveform.path.ecg"
                )
                MetricTile(
                    title: "Configured Sends",
                    value: "\(metrics.sendsPerPacket ?? 1)x",
                    detail: L10n.string("+%@ duplicate copy/packet", "\(metrics.duplicateCopiesPerPacket ?? 0)"),
                    systemImage: "repeat"
                )
                MetricTile(
                    title: "Bridge Errors",
                    value: "\(metrics.bridgeReadErrors + metrics.bridgeWriteErrors + metrics.bridgeShortWrites)",
                    detail: L10n.string("read %@  write %@  short %@", "\(metrics.bridgeReadErrors)", "\(metrics.bridgeWriteErrors)", "\(metrics.bridgeShortWrites)"),
                    systemImage: "exclamationmark.triangle"
                )
                MetricTile(
                    title: "ARQ Resends",
                    value: "\(arqTotalResends)",
                    detail: L10n.string("data %@  control %@", "\(arqDataResends)", "\(arqControlResends)"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                MetricTile(
                    title: "ARQ NACKs",
                    value: L10n.string("%@ rx", "\(metrics.arqDataNackPacketsReceived ?? 0)"),
                    detail: L10n.string("%@ sent  %@ resend queued", "\(metrics.arqDataNackPacketsSent ?? 0)", "\(metrics.arqDataNackResendsQueued ?? 0)"),
                    systemImage: "arrow.uturn.backward.circle"
                )
                MetricTile(
                    title: "ARQ Streams",
                    value: L10n.string("%@ active", "\(metrics.arqStreamsActive ?? 0)"),
                    detail: L10n.string("%@ created  %@ closed", "\(metrics.arqStreamsCreated ?? 0)", "\(metrics.arqStreamsClosed ?? 0)"),
                    systemImage: "point.3.connected.trianglepath.dotted"
                )
                MetricTile(
                    title: "ARQ Queue Rejects",
                    value: "\(arqQueueRejected)",
                    detail: L10n.string("%@ ACK rejects", "\(arqAckRejected)"),
                    systemImage: "xmark.octagon"
                )
                MetricTile(
                    title: "FEC Recovery",
                    value: "\(metrics.fecRecoveredPackets ?? 0)",
                    detail: L10n.string("%@ decoded groups  %@ symbols rx", "\(metrics.fecDecodedGroups ?? 0)", "\(metrics.fecSymbolsReceived ?? 0)"),
                    systemImage: "lifepreserver"
                )
            }

            VStack(spacing: 8) {
                MetricRow(title: "Status", value: "\(metrics.status) / \(metrics.phase)")
                MetricRow(title: "Runtime", value: L10n.string("%@ (%@)", runtimeDisplayName, metrics.runtimeModeSource ?? L10n.string("unknown source")))
                MetricRow(title: "Provider Heartbeat", value: metrics.providerHeartbeatAt.map(relativeTime) ?? "n/a")
                MetricRow(title: "Provider Lifecycle", value: metrics.providerLastLifecycleEvent ?? "n/a")
                if let stopReasonName = metrics.providerStopReasonName {
                    MetricRow(title: "Provider Stop Reason", value: L10n.string("%@ (%@)", stopReasonName, metrics.providerStopReasonRaw.map(String.init) ?? "n/a"))
                }
                if let hevExitCode = metrics.hevExitCode {
                    MetricRow(title: "HEV Exit Code", value: "\(hevExitCode)")
                }
                if let packetBridgeExitCode = metrics.packetBridgeExitCode {
                    MetricRow(title: "Packet Bridge Exit", value: "\(packetBridgeExitCode)")
                }
                if !providerResourceSummary.isEmpty {
                    MetricRow(title: "Provider Resources", value: providerResourceSummary)
                }
                MetricRow(title: "Session", value: metrics.sessionID.map(String.init) ?? "n/a")
                MetricRow(title: "Resolver", value: metrics.resolverAddress ?? "n/a")
                MetricRow(title: "MTU", value: L10n.string("up %@ / down %@", metrics.uploadMTU.map(String.init) ?? L10n.string("n/a"), metrics.downloadMTU.map(String.init) ?? L10n.string("n/a")))
                MetricRow(title: "Resolvers", value: L10n.string("accepted %@ / rejected %@", metrics.acceptedResolvers.map(String.init) ?? L10n.string("n/a"), metrics.rejectedResolvers.map(String.init) ?? L10n.string("n/a")))
                MetricRow(title: "Traffic Source", value: "iOS packet-flow bridge counters")
                MetricRow(title: "Bridge Packets", value: L10n.string("%@ app->engine / %@ engine->app", "\(metrics.bridgeInputPackets)", "\(metrics.bridgeOutputPackets)"))
                MetricRow(title: "Bridge Bytes", value: L10n.string("%@ app->engine / %@ engine->app", formatBytes(metrics.bridgeInputBytes), formatBytes(metrics.bridgeOutputBytes)))
                MetricRow(title: "First Packet In", value: metrics.firstBridgeInputAt.map(relativeTime) ?? "n/a")
                MetricRow(title: "First Packet Out", value: metrics.firstBridgeOutputAt.map(relativeTime) ?? "n/a")
                if metrics.runtimeMode == MasterDNSRuntimeMode.nativePacket.rawValue {
                    MetricRow(title: "Native Packets", value: L10n.string("%@ in / %@ out", "\(metrics.nativeInputPackets ?? metrics.bridgeInputPackets)", "\(metrics.nativeOutputPackets ?? metrics.bridgeOutputPackets)"))
                    MetricRow(title: "Native TCP", value: L10n.string("%@ active / %@ created / %@ closed", "\(metrics.nativeTCPFlowsActive ?? 0)", "\(metrics.nativeTCPFlowsCreated ?? 0)", "\(metrics.nativeTCPFlowsClosed ?? 0)"))
                    MetricRow(title: "Native TCP Endpoint", value: L10n.string("%@ errors / %@ resets", "\(metrics.nativeTCPEndpointErrors ?? 0)", "\(metrics.nativeTCPEndpointResets ?? 0)"))
                    MetricRow(title: "Native DNS", value: L10n.string("%@ queries / %@ responses / %@ pending", "\(metrics.nativeDNSQueries ?? 0)", "\(metrics.nativeDNSResponses ?? 0)", "\(metrics.nativeDNSPending ?? 0)"))
                    MetricRow(title: "Native UDP", value: L10n.string("%@ unsupported / %@ rejected", "\(metrics.nativeUnsupportedUDP ?? 0)", "\(metrics.nativeUnsupportedUDPRejects ?? 0)"))
                    if let topPorts = metrics.nativeUnsupportedUDPTopPorts, !topPorts.isEmpty {
                        MetricRow(title: "Native UDP Ports", value: topPorts)
                    }
                    MetricRow(title: "Native Writes", value: L10n.string("%@ packet-flow writes / %@ rejects / %@ engine errors", "\(metrics.nativePacketFlowWritePackets ?? 0)", "\(metrics.nativePacketFlowWriteFailures ?? 0)", "\(metrics.nativePacketWriteErrors ?? 0)"))
                }
                MetricRow(title: "ARQ Resend Ratio", value: L10n.string("%@ = resends / queued ARQ packets", arqResendRatio))
                MetricRow(title: "ARQ Acked", value: L10n.string("%@ total / %@ data / %@ control", "\(arqTotalAcked)", "\(metrics.arqDataPacketsAcked ?? 0)", "\(metrics.arqControlPacketsAcked ?? 0)"))
                MetricRow(title: "ARQ Data TX", value: L10n.string("read %@ / queued %@ / dequeued %@", "\(metrics.arqDataPacketsRead ?? 0)", "\(metrics.arqDataPacketsQueued ?? 0)", "\(metrics.arqDataPacketsDequeued ?? 0)"))
                MetricRow(title: "ARQ Data RX", value: L10n.string("received %@ / ACK sent %@ / ACK reject %@", "\(metrics.arqDataPacketsReceived ?? 0)", "\(metrics.arqDataAckPacketsSent ?? 0)", "\(metrics.arqDataAckPacketsRejected ?? 0)"))
                MetricRow(title: "ARQ Data Resend", value: L10n.string("total %@ / timeout %@ / NACK %@", "\(arqDataResends)", "\(metrics.arqDataTimeoutResendsQueued ?? 0)", "\(metrics.arqDataNackResendsQueued ?? 0)"))
                MetricRow(title: "ARQ Data Rejects", value: L10n.string("data %@ / resend %@ / NACK %@", "\(metrics.arqDataPacketsQueueRejected ?? 0)", "\(metrics.arqDataResendsRejected ?? 0)", "\(metrics.arqDataNackPacketsRejected ?? 0)"))
                MetricRow(title: "ARQ Control", value: L10n.string("queued %@ / dequeued %@ / acked %@", "\(metrics.arqControlPacketsQueued ?? 0)", "\(metrics.arqControlPacketsDequeued ?? 0)", "\(metrics.arqControlPacketsAcked ?? 0)"))
                MetricRow(title: "ARQ Control Resend", value: L10n.string("queued %@ / rejected %@", "\(arqControlResends)", "\(metrics.arqControlResendsRejected ?? 0)"))
                MetricRow(title: "ARQ Expiry", value: L10n.string("data max %@ ttl %@ / control max %@ ttl %@", "\(metrics.arqDataMaxRetriesExceeded ?? 0)", "\(metrics.arqDataTTLExpired ?? 0)", "\(metrics.arqControlMaxRetriesExceeded ?? 0)", "\(metrics.arqControlTTLExpired ?? 0)"))
                MetricRow(title: "FEC Negotiated", value: "\(metrics.fecNegotiated ?? 0)")
                MetricRow(title: "FEC Symbols", value: L10n.string("sent %@ / received %@ / overhead %@", "\(metrics.fecSymbolsSent ?? 0)", "\(metrics.fecSymbolsReceived ?? 0)", formatBytes(metrics.fecOverheadBytes ?? 0)))
                MetricRow(title: "FEC Groups", value: L10n.string("created %@ / decoded %@ / failed %@", "\(metrics.fecGroupsCreated ?? 0)", "\(metrics.fecDecodedGroups ?? 0)", "\(metrics.fecFailedGroups ?? 0)"))
                MetricRow(title: "Engine", value: metrics.engineRunning == true ? L10n.string("running") : L10n.string("not running"))
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
            Label(L10n.string(title), systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(L10n.string(value))
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(L10n.string(detail))
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
            Text(L10n.string(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(L10n.string(value))
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
            Text(L10n.string(title))
            Spacer()
            Text(L10n.string(value))
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
            return L10n.string("Not run")
        case .passed:
            return L10n.string("Passed")
        case .warning:
            return L10n.string("Review")
        case .failed:
            return L10n.string("Failed")
        case .skipped:
            return L10n.string("Skipped")
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
    L10n.string("%@/s", formatBytes(UInt64(max(0, bytesPerSecond))))
}

private func formatDuration(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    if hours > 0 {
        return L10n.string("%dh %dm", hours, minutes)
    }
    if minutes > 0 {
        return L10n.string("%dm %ds", minutes, secs)
    }
    return L10n.string("%ds", secs)
}

private func relativeTime(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 2 {
        return L10n.string("now")
    }
    return L10n.string("%@ ago", L10n.string("%ds", seconds))
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
