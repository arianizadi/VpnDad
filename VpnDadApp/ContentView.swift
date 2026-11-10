import CoreImage.CIFilterBuiltins
import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Home

struct ContentView: View {
    @StateObject private var model = ProfileListModel()
    @StateObject private var vpn = VPNController()
    @AppStorage(AppConstants.advancedModeDefaultsKey) private var advancedMode = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false

    /// Profile the home screen's power button acts on: the one the tunnel
    /// last used, or the first profile when nothing has connected yet.
    private var quickProfile: VPNProfile? {
        model.profiles.first { $0.id == vpn.activeProfileID } ?? model.profiles.first
    }

    var body: some View {
        NavigationView {
            List {
                if let quickProfile {
                    Section {
                        ConnectionHero(profile: quickProfile, model: model, vpn: vpn, showsProfileName: true)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if !model.profiles.isEmpty {
                    Section("Profiles") {
                        ForEach(model.profiles) { profile in
                            NavigationLink {
                                ProfileDetailView(profile: profile, model: model, vpn: vpn)
                            } label: {
                                ProfileRow(
                                    profile: profile,
                                    status: vpn.isActive(profile) ? vpn.status : .disconnected,
                                    showsDetail: advancedMode
                                )
                            }
                        }
                        .onDelete { offsets in
                            offsets.map { model.profiles[$0] }.forEach(model.delete)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(.default, value: model.profiles)
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
                    EmptyProfilesView { importing = true }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task {
            model.reload()
            await vpn.refresh()
        }
        .onChange(of: scenePhase) { phase in
            // The tunnel can change state while the app is suspended.
            if phase == .active {
                Task { await vpn.refresh() }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            model.importFile(result)
        }
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

struct EmptyProfilesView: View {
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(26)
                .background(Circle().fill(Color.accentColor.opacity(0.12)))
            Text("No Profiles")
                .font(.title3.weight(.semibold))
            Text("Import a profile to get started.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: onImport) {
                Label("Import Profile", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .padding(.horizontal, 8)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 6)
        }
        .padding(32)
    }
}

struct ProfileRow: View {
    let profile: VPNProfile
    let status: NEVPNStatus
    let showsDetail: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: profile.tunnelProtocol == .masterdns ? "network" : "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(status.tint == .secondary ? Color.accentColor : status.tint)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill((status.tint == .secondary ? Color.accentColor : status.tint).opacity(0.14))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.body.weight(.medium))
                if status != .disconnected, status != .invalid {
                    Text(status.displayName)
                        .font(.caption)
                        .foregroundStyle(status.tint)
                } else if showsDetail {
                    Text("\(profile.tunnelProtocol.rawValue) · \(profile.domain)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if status == .connected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.vertical, 3)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: status)
    }
}

// MARK: - Connection hero

/// Startup stages reported by the tunnel extension, in order.
enum ConnectStep: Int, CaseIterable, Identifiable {
    case prepare, network, engine, handshake, bridge

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .prepare: return L10n.string("Preparing profile")
        case .network: return L10n.string("Configuring network")
        case .engine: return L10n.string("Starting engine")
        case .handshake: return L10n.string("Testing resolvers")
        case .bridge: return L10n.string("Starting packet bridge")
        }
    }

    static func current(metrics: TunnelMetrics?, attemptStartedAt: Date?) -> ConnectStep {
        guard let metrics, metrics.status == "starting" || metrics.status == "running" else {
            return .prepare
        }
        // Metrics from an earlier session say nothing about this attempt.
        if let attemptStartedAt, metrics.updatedAt < attemptStartedAt.addingTimeInterval(-2) {
            return .prepare
        }
        switch metrics.phase {
        case "applying network settings":
            return .network
        case "engine starting", "engine running":
            return .engine
        case "engine handshake":
            return .handshake
        case let phase where phase.contains("bridge") || phase == "running":
            return .bridge
        default:
            return .prepare
        }
    }
}

struct ConnectionHero: View {
    let profile: VPNProfile
    @ObservedObject var model: ProfileListModel
    @ObservedObject var vpn: VPNController
    var showsProfileName = false

    @State private var requesting = false

    private var status: NEVPNStatus {
        requesting && vpn.status(for: profile) != .connected ? .connecting : vpn.status(for: profile)
    }

    private var metrics: TunnelMetrics? {
        guard let metrics = model.tunnelMetrics, metrics.profileName == profile.name else {
            return nil
        }
        return metrics
    }

    private var isBusy: Bool {
        status == .connecting || status == .reasserting || status == .disconnecting
    }

    private var steps: [ConnectStep] {
        profile.tunnelProtocol == .masterdns
            ? ConnectStep.allCases
            : ConnectStep.allCases.filter { $0 != .handshake }
    }

    /// Why the last attempt for this profile ended, if it failed recently.
    private var failureMessage: String? {
        guard status == .disconnected || status == .invalid,
              let metrics, metrics.status == "failed",
              Date().timeIntervalSince(metrics.updatedAt) < 120 else {
            return nil
        }
        return metrics.lastError ?? metrics.engineLastError ?? L10n.string("Unknown")
    }

    private var glowTint: Color {
        if failureMessage != nil {
            return .red
        }
        return status.tint == .secondary ? Color.accentColor : status.tint
    }

    /// Share of startup stages completed, for the ring around the button.
    private var connectProgress: Double? {
        guard status == .connecting || status == .reasserting else {
            return nil
        }
        let current = ConnectStep.current(metrics: metrics, attemptStartedAt: vpn.connectStartedAt)
        let index = steps.firstIndex(of: current) ?? 0
        return (Double(index) + 0.5) / Double(steps.count)
    }

    private var pollIntervalNanoseconds: UInt64 {
        switch status {
        case .connecting, .reasserting, .disconnecting:
            return 400_000_000
        case .connected:
            return 1_000_000_000
        default:
            return 3_000_000_000
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Button(action: toggle) {
                PowerOrb(status: status, failed: failureMessage != nil, progress: connectProgress)
            }
            .buttonStyle(OrbButtonStyle())
            .disabled(status == .disconnecting)
            .accessibilityLabel(status == .connected || isBusy ? Text("Disconnect") : Text("Connect"))

            VStack(spacing: 4) {
                // `.invalid` just means no VPN configuration is installed yet.
                Text(failureMessage != nil
                    ? L10n.string("Couldn't connect")
                    : (status == .invalid ? NEVPNStatus.disconnected : status).displayName)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(failureMessage != nil ? Color.red : Color.primary)
                    .id(failureMessage != nil ? -1 : status.rawValue)
                    .transition(.asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
                subtitle
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            detail
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .padding(.bottom, 22)
        .padding(.horizontal, 16)
        .background(
            ZStack {
                Color(.secondarySystemGroupedBackground)
                AmbientGlow(tint: glowTint, active: status == .connected || isBusy)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: status)
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: failureMessage)
        .onChange(of: vpn.status) { _ in
            // Pick up the extension's final metrics (e.g. a failure reason)
            // right away instead of on the next poll.
            model.reloadTunnelMetrics()
        }
        .task(id: pollIntervalNanoseconds) {
            while !Task.isCancelled {
                model.reloadTunnelMetrics()
                try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
            }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        if let failureMessage {
            Text(cleanLogLine(failureMessage))
                .lineLimit(4)
        } else if status == .connected {
            HStack(spacing: 6) {
                if showsProfileName {
                    Text(profile.name)
                    Text("·")
                }
                UptimeText(startedAt: metrics?.startedAt)
            }
        } else if isBusy {
            if status == .disconnecting {
                Text(profile.name)
            } else {
                ElapsedText(since: vpn.connectStartedAt)
            }
        } else if showsProfileName {
            Text(profile.name)
        } else {
            Text("Tap to connect")
        }
    }

    @ViewBuilder
    private var detail: some View {
        if status == .connecting || status == .reasserting {
            ConnectProgressList(
                steps: steps,
                current: ConnectStep.current(metrics: metrics, attemptStartedAt: vpn.connectStartedAt),
                liveDetail: metrics?.lastLogLine.map(cleanLogLine)
            )
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else if status == .connected, let metrics {
            HStack(spacing: 10) {
                RateTile(
                    title: "Download",
                    systemImage: "arrow.down",
                    tint: .green,
                    rate: metrics.downloadBytesPerSecond,
                    total: metrics.downloadBytes
                )
                RateTile(
                    title: "Upload",
                    systemImage: "arrow.up",
                    tint: .blue,
                    rate: metrics.uploadBytesPerSecond,
                    total: metrics.uploadBytes
                )
            }
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
    }

    private func toggle() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if status == .connected || isBusy {
            vpn.disconnect()
            return
        }
        Task {
            requesting = true
            defer { requesting = false }
            do {
                try await vpn.connect(profile: profile)
            } catch {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
                model.errorMessage = error.localizedDescription
            }
            model.reloadTunnelMetrics()
        }
    }
}

/// The big power button. Idle: a quiet ring. Connecting: a ring that fills
/// as startup stages complete, with a light sweeping round it. Connected: a
/// lit glass button that breathes and sends slow ripples outward.
struct PowerOrb: View {
    let status: NEVPNStatus
    let failed: Bool
    /// 0...1 while connecting; nil when there is nothing to measure.
    var progress: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color {
        if failed {
            return .red
        }
        return status.tint == .secondary ? Color.accentColor : status.tint
    }

    private var isSpinning: Bool {
        status == .connecting || status == .reasserting || status == .disconnecting
    }

    private var isOn: Bool { status == .connected }

    private let ringSize: CGFloat = 148
    private let coreSize: CGFloat = 116

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !(isSpinning || isOn))) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let breath = isOn && !reduceMotion ? (sin(time * 1.5) + 1) / 2 : 0

            ZStack {
                if isOn && !reduceMotion {
                    ForEach(0..<3, id: \.self) { index in
                        let phase = (time / 3.2 + Double(index) / 3).truncatingRemainder(dividingBy: 1)
                        Circle()
                            .stroke(tint.opacity((1 - phase) * 0.32), lineWidth: 1.5)
                            .frame(width: ringSize + phase * 96, height: ringSize + phase * 96)
                    }
                }

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [tint.opacity(isOn ? 0.30 + 0.12 * breath : 0.16), tint.opacity(0)],
                            center: .center,
                            startRadius: coreSize / 2 - 8,
                            endRadius: 118
                        )
                    )
                    .frame(width: 236, height: 236)

                Circle()
                    .stroke(tint.opacity(isOn ? 0.95 : 0.16), lineWidth: 4)
                    .frame(width: ringSize, height: ringSize)

                if isSpinning {
                    Circle()
                        .trim(from: 0, to: max(0.03, progress ?? 0))
                        .stroke(tint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .frame(width: ringSize, height: ringSize)
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(response: 0.7, dampingFraction: 0.85), value: progress)

                    Circle()
                        .trim(from: 0, to: 0.22)
                        .stroke(
                            AngularGradient(
                                colors: [.white.opacity(0), .white.opacity(0.85)],
                                center: .center,
                                startAngle: .degrees(0),
                                endAngle: .degrees(80)
                            ),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: ringSize, height: ringSize)
                        .rotationEffect(.degrees(reduceMotion ? 0 : time.truncatingRemainder(dividingBy: 1.4) / 1.4 * 360))
                        .blendMode(.plusLighter)
                        .transition(.opacity)
                }

                Circle()
                    .fill(
                        isOn
                            ? AnyShapeStyle(LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.72)],
                                startPoint: .top,
                                endPoint: .bottom
                            ))
                            : AnyShapeStyle(.ultraThinMaterial)
                    )
                    .overlay(
                        // Soft top highlight and hairline edge give the core
                        // its glass look.
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [.white.opacity(isOn ? 0.34 : 0.14), .white.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .center
                                )
                            )
                    )
                    .overlay(
                        Circle().strokeBorder(.white.opacity(isOn ? 0.35 : 0.12), lineWidth: 1)
                    )
                    .frame(width: coreSize, height: coreSize)
                    .shadow(color: tint.opacity(isOn ? 0.45 + 0.15 * breath : 0.12), radius: isOn ? 22 : 10, y: 8)
                    .scaleEffect(1 + 0.015 * breath)

                Image(systemName: failed ? "exclamationmark" : "power")
                    .font(.system(size: 42, weight: .semibold, design: .rounded))
                    .foregroundStyle(isOn ? Color.white : tint)
                    .shadow(color: .black.opacity(isOn ? 0.18 : 0), radius: 3, y: 2)
            }
            .frame(width: 250, height: 250)
        }
        .animation(.easeInOut(duration: 0.5), value: status)
        .animation(.easeInOut(duration: 0.5), value: failed)
    }
}

/// Slow-drifting colour wash behind the hero. It takes the state colour, so
/// the whole card warms to amber while connecting and settles into green.
struct AmbientGlow: View {
    let tint: Color
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion || !active)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let width = proxy.size.width
                let height = proxy.size.height
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.42))
                        .frame(width: width * 0.8, height: width * 0.8)
                        .offset(x: cos(time * 0.35) * width * 0.18 - width * 0.2, y: sin(time * 0.28) * 26 - height * 0.28)
                    Circle()
                        .fill(tint.opacity(0.26))
                        .frame(width: width * 0.7, height: width * 0.7)
                        .offset(x: sin(time * 0.3) * width * 0.2 + width * 0.25, y: cos(time * 0.24) * 30 + height * 0.3)
                }
                .frame(width: width, height: height)
                .blur(radius: 70)
            }
        }
        .animation(.easeInOut(duration: 0.9), value: tint)
        .allowsHitTesting(false)
    }
}

private extension View {
    /// Liquid Glass where the OS has it, a thin material everywhere else.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
        }
    }

    /// Digits roll instead of snapping where the OS supports it.
    @ViewBuilder
    func numericTransition() -> some View {
        if #available(iOS 16.0, *) {
            contentTransition(.numericText())
        } else {
            self
        }
    }
}

struct OrbButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct ConnectProgressList: View {
    let steps: [ConnectStep]
    let current: ConnectStep
    let liveDetail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(steps) { step in
                HStack(spacing: 10) {
                    ZStack {
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .transition(.scale.combined(with: .opacity))
                        } else if step == current {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 20, height: 20)

                    Text(step.title)
                        .font(.subheadline.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
                    Spacer(minLength: 0)
                }
            }

            if let liveDetail, !liveDetail.isEmpty {
                Text(liveDetail)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .glassCard(cornerRadius: 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: current)
    }
}

struct RateTile: View {
    let title: String
    let systemImage: String
    let tint: Color
    let rate: Double
    let total: UInt64

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(Circle().fill(tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(formatRate(rate))
                    .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                    .numericTransition()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(formatBytes(total))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 20)
    }
}

/// Uptime that ticks every second without waiting for a metrics poll.
struct UptimeText: View {
    let startedAt: Date?

    var body: some View {
        if let startedAt {
            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                Text(formatDuration(max(0, Int(context.date.timeIntervalSince(startedAt)))))
                    .monospacedDigit()
            }
        } else {
            Text("Connected")
        }
    }
}

struct ElapsedText: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 1)) { context in
                Text(formatDuration(max(0, Int(context.date.timeIntervalSince(since)))))
                    .monospacedDigit()
            }
        } else {
            Text(" ")
        }
    }
}

// MARK: - Profile detail

struct ProfileDetailView: View {
    let profile: VPNProfile
    @ObservedObject var model: ProfileListModel
    @ObservedObject var vpn: VPNController
    @AppStorage(AppConstants.advancedModeDefaultsKey) private var advancedMode = false
    @Environment(\.dismiss) private var dismiss
    @StateObject private var health = HealthModel()
    @State private var exporting = false
    @State private var exportDocument = ProfileDocument()
    @State private var diagnosticExporting = false
    @State private var diagnosticDocument = ProfileDocument()
    @State private var editingProfile = false
    @State private var confirmingDelete = false
    @State private var showingQRCode = false

    private let healthProbeColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    /// Tunnel status as it applies to this profile.
    private var status: NEVPNStatus {
        vpn.status(for: profile)
    }

    /// Metrics only describe this profile if its tunnel wrote them.
    private var metrics: TunnelMetrics? {
        guard let metrics = model.tunnelMetrics, metrics.profileName == profile.name else {
            return nil
        }
        return metrics
    }

    private var currentProbe: HealthProbeSnapshot? {
        guard health.probeSnapshot?.profileID == profile.id else {
            return nil
        }
        return health.probeSnapshot
    }

    private func makeHealthReport() -> TunnelHealthReport {
        TunnelHealthEvaluator.evaluate(
            profile: profile,
            vpnStatus: status,
            metrics: metrics,
            probe: currentProbe,
            // The log only feeds the advanced timeline.
            tunnelLog: advancedMode ? model.tunnelLog : ""
        )
    }

    var body: some View {
        Form {
            Section {
                ConnectionHero(profile: profile, model: model, vpn: vpn)
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            healthSection

            if advancedMode {
                profileInfoSection
                liveMetricsSection
                tunnelLogSection
                exportSection
            }
        }
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
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
                    }
                    Button(role: .destructive) {
                        confirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Delete Profile?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if vpn.isActive(profile) {
                    vpn.disconnect()
                }
                model.delete(profile)
                dismiss()
            }
        } message: {
            Text("This removes the profile and its saved key from this device.")
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
            health.reload()
        }
        .task(id: advancedMode) {
            // Only the advanced sections show the log; the hero polls metrics.
            guard advancedMode else {
                return
            }
            while !Task.isCancelled {
                model.reloadTunnelLog()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task(id: "\(profile.id.uuidString)-\(status.rawValue)") {
            guard status == .connected else {
                health.resetAutomaticRun()
                return
            }
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if Task.isCancelled {
                return
            }
            model.reloadTunnelMetrics()
            await health.runAutomaticIfNeeded(profile: profile, vpnStatus: status, metrics: metrics)
        }
    }

    private var healthSection: some View {
        // Evaluate once per render; the report feeds two subviews.
        let report = makeHealthReport()
        return Section("Health") {
            HealthSummaryView(report: report, maxEvidence: advancedMode ? 5 : 2)

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
                    HealthTimelineView(events: report.timeline)
                } label: {
                    Label("Connection Timeline", systemImage: "timeline.selection")
                }
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
            if let metrics {
                Text(L10n.string("Updated %@", relativeTime(metrics.updatedAt)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    UIPasteboard.general.string = model.tunnelLog
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                } label: {
                    Label("Copy Log", systemImage: "doc.on.doc")
                }
                .disabled(model.tunnelLog.isEmpty)

                Spacer()

                Button(role: .destructive) {
                    model.clearTunnelLog()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
            .buttonStyle(.borderless)

            if model.tunnelLog.isEmpty {
                Text("No tunnel log yet")
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    // Show the tail only: laying out the whole log as one
                    // Text on every refresh is what made this screen stutter.
                    Text(String(model.tunnelLog.suffix(12_000)))
                        .font(.caption2.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    private var exportSection: some View {
        Section {
            Button {
                withAnimation {
                    showingQRCode.toggle()
                }
            } label: {
                Label("Show QR Code", systemImage: "qrcode")
            }

            if showingQRCode, let exportText = model.exportText(for: profile) {
                QRCodeView(text: exportText)
                    .frame(maxWidth: .infinity, minHeight: 220)
            }

            Button {
                if let data = model.exportText(for: profile)?.data(using: .utf8) {
                    exportDocument = ProfileDocument(data: data)
                    exporting = true
                }
            } label: {
                Label("Export JSON", systemImage: "square.and.arrow.up")
            }
        }
    }

    private func runHealthCheck(_ kind: HealthProbeKind) async {
        model.reloadTunnelMetrics()
        await health.runCheck(kind, profile: profile, vpnStatus: status, metrics: metrics)
        model.reloadTunnelMetrics()
        model.reloadTunnelLog()
    }

    private func runAllHealthChecks() async {
        model.reloadTunnelMetrics()
        await health.runAllChecks(profile: profile, vpnStatus: status, metrics: metrics)
        model.reloadTunnelMetrics()
        model.reloadTunnelLog()
    }

    private func exportDiagnosticBundle() {
        model.reloadTunnelMetrics()
        model.reloadTunnelLog()
        let report = TunnelHealthEvaluator.evaluate(
            profile: profile,
            vpnStatus: status,
            metrics: metrics,
            probe: currentProbe,
            tunnelLog: model.tunnelLog
        )
        do {
            let data = try DiagnosticBundleBuilder.makeData(
                profile: profile,
                vpnStatus: status,
                metrics: metrics,
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
            HStack(spacing: 10) {
                Image(systemName: report.verdict.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(report.verdict.tint)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(report.verdict.tint.opacity(0.15)))
                Text(report.verdict.displayName)
                    .font(.headline)
                    .foregroundStyle(report.verdict.tint)
            }
            .animation(.easeInOut(duration: 0.3), value: report.verdict)

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
                ForEach(Array(events.enumerated()), id: \.offset) { _, event in
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
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
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

    // These two are polled. They publish only on change so an idle screen
    // does not re-render, and they stay quiet on failure: a transient read
    // error must not raise an alert every poll.
    func reloadTunnelLog() {
        guard let log = try? repository.readTunnelLog(), log != tunnelLog else {
            return
        }
        tunnelLog = log
    }

    func reloadTunnelMetrics() {
        guard let metrics = try? repository.readTunnelMetrics(), metrics != tunnelMetrics else {
            return
        }
        tunnelMetrics = metrics
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
    return L10n.string("%@ ago", formatDuration(seconds))
}

/// Engine log lines carry colour markup such as `<green>…</green>`.
private func cleanLogLine(_ line: String) -> String {
    line.replacingOccurrences(of: "</?[a-zA-Z]+>", with: "", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

extension NEVPNStatus {
    var tint: Color {
        switch self {
        case .connected:
            return .green
        case .connecting, .reasserting, .disconnecting:
            return .orange
        default:
            return .secondary
        }
    }
}

struct QRCodeView: View {
    let text: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white))
                    .padding()
            } else {
                ProgressView()
            }
        }
        // Rendered once per payload instead of on every view update.
        .task(id: text) {
            image = Self.makeImage(text)
        }
    }

    private static func makeImage(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return nil
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
