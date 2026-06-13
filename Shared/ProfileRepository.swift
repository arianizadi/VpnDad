import Darwin
import Foundation

enum ProfileRepositoryError: LocalizedError {
    case profileNotFound
    case missingSecret(String)
    case invalidProfile(String)
    case sharedContainerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .profileNotFound:
            return L10n.string("Profile was not found")
        case .missingSecret(let key):
            return L10n.string("Missing profile secret: %@", key)
        case .invalidProfile(let reason):
            return reason
        case .sharedContainerUnavailable(let identifier):
            return L10n.string("App Group container is unavailable: %@", identifier)
        }
    }
}

struct TunnelMetrics: Codable, Equatable {
    var status: String
    var phase: String
    var profileName: String
    var tunnelProtocol: String
    var socksAddress: String
    var startedAt: Date?
    var updatedAt: Date
    var uptimeSeconds: Int

    var providerStartedAt: Date? = nil
    var providerHeartbeatAt: Date? = nil
    var providerLastTelemetryWriteAt: Date? = nil
    var providerStoppingAt: Date? = nil
    var providerStoppedAt: Date? = nil
    var providerStopReasonRaw: Int? = nil
    var providerStopReasonName: String? = nil
    var providerLastLifecycleEvent: String? = nil
    var runtimeMode: String? = nil
    var runtimeModeSource: String? = nil
    var hevRunning: Bool? = nil
    var hevExitCode: Int? = nil
    var hevExitedAt: Date? = nil
    var packetBridgeExitedAt: Date? = nil
    var packetBridgeExitCode: Int? = nil
    var memoryResidentBytes: UInt64? = nil
    var memoryPhysicalFootprintBytes: UInt64? = nil
    var threadCount: Int? = nil
    var openFileDescriptorCount: Int? = nil

    var resolverAddress: String? = nil
    var sessionID: Int? = nil
    var uploadMTU: Int? = nil
    var downloadMTU: Int? = nil
    var acceptedResolvers: Int? = nil
    var rejectedResolvers: Int? = nil

    var sendsPerPacket: Int? = nil
    var duplicateCopiesPerPacket: Int? = nil

    var arqStreamsCreated: UInt64? = nil
    var arqStreamsClosed: UInt64? = nil
    var arqStreamsActive: UInt64? = nil
    var arqDataPacketsRead: UInt64? = nil
    var arqDataPacketsQueued: UInt64? = nil
    var arqDataPacketsQueueRejected: UInt64? = nil
    var arqDataPacketsDequeued: UInt64? = nil
    var arqDataPacketsAcked: UInt64? = nil
    var arqDataPacketsReceived: UInt64? = nil
    var arqDataAckPacketsSent: UInt64? = nil
    var arqDataAckPacketsRejected: UInt64? = nil
    var arqDataNackPacketsSent: UInt64? = nil
    var arqDataNackPacketsRejected: UInt64? = nil
    var arqDataNackPacketsReceived: UInt64? = nil
    var arqDataResendsQueued: UInt64? = nil
    var arqDataResendsRejected: UInt64? = nil
    var arqDataNackResendsQueued: UInt64? = nil
    var arqDataNackResendsRejected: UInt64? = nil
    var arqDataTimeoutResendsQueued: UInt64? = nil
    var arqDataTimeoutResendsRejected: UInt64? = nil
    var arqDataMaxRetriesExceeded: UInt64? = nil
    var arqDataTTLExpired: UInt64? = nil
    var arqControlPacketsQueued: UInt64? = nil
    var arqControlPacketsQueueRejected: UInt64? = nil
    var arqControlPacketsDequeued: UInt64? = nil
    var arqControlPacketsAcked: UInt64? = nil
    var arqControlResendsQueued: UInt64? = nil
    var arqControlResendsRejected: UInt64? = nil
    var arqControlMaxRetriesExceeded: UInt64? = nil
    var arqControlTTLExpired: UInt64? = nil
    var fecNegotiated: UInt64? = nil
    var fecGroupsCreated: UInt64? = nil
    var fecSymbolsSent: UInt64? = nil
    var fecSymbolsReceived: UInt64? = nil
    var fecDecodedGroups: UInt64? = nil
    var fecRecoveredPackets: UInt64? = nil
    var fecFailedGroups: UInt64? = nil
    var fecOverheadBytes: UInt64? = nil

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
    var firstBridgeInputAt: Date? = nil
    var firstBridgeOutputAt: Date? = nil
    var bridgeReadErrors: UInt64
    var bridgeWriteErrors: UInt64
    var bridgeShortWrites: UInt64
    var lastBridgeError: String? = nil

    var nativeTCPFlowsActive: UInt64? = nil
    var nativeTCPFlowsCreated: UInt64? = nil
    var nativeTCPFlowsClosed: UInt64? = nil
    var nativeTCPEndpointErrors: UInt64? = nil
    var nativeTCPEndpointResets: UInt64? = nil
    var nativeInputPackets: UInt64? = nil
    var nativeInputBytes: UInt64? = nil
    var nativeOutputPackets: UInt64? = nil
    var nativeOutputBytes: UInt64? = nil
    var nativeDNSQueries: UInt64? = nil
    var nativeDNSCacheHits: UInt64? = nil
    var nativeDNSPending: UInt64? = nil
    var nativeDNSResponses: UInt64? = nil
    var nativeUnsupportedUDP: UInt64? = nil
    var nativeUnsupportedUDPRejects: UInt64? = nil
    var nativeUnsupportedUDPTopPorts: String? = nil
    var nativeMalformedPackets: UInt64? = nil
    var nativePacketWriteErrors: UInt64? = nil
    var nativePacketFlowWritePackets: UInt64? = nil
    var nativePacketFlowWriteBytes: UInt64? = nil
    var nativePacketFlowWriteFailures: UInt64? = nil
    var nativePacketFlowDroppedPackets: UInt64? = nil
    var nativePacketFlowInvalidOutputPackets: UInt64? = nil

    var engineRunning: Bool? = nil
    var engineStartedAt: String? = nil
    var engineLastError: String? = nil
    var engineStatusJSON: String

    var lastLogLine: String? = nil
    var lastError: String? = nil

    static var empty: TunnelMetrics {
        TunnelMetrics(
            status: "unknown",
            phase: "idle",
            profileName: "",
            tunnelProtocol: "",
            socksAddress: "",
            startedAt: nil,
            updatedAt: Date(),
            uptimeSeconds: 0,
            uploadPackets: 0,
            downloadPackets: 0,
            uploadBytes: 0,
            downloadBytes: 0,
            totalBytes: 0,
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            totalBytesPerSecond: 0,
            bridgeInputPackets: 0,
            bridgeInputBytes: 0,
            bridgeOutputPackets: 0,
            bridgeOutputBytes: 0,
            bridgeReadErrors: 0,
            bridgeWriteErrors: 0,
            bridgeShortWrites: 0,
            engineStatusJSON: "{}"
        )
    }
}

enum HealthProbeCheckStatus: String, Codable, Equatable {
    case notRun
    case passed
    case warning
    case failed
    case skipped
}

struct HealthProbeCheck: Codable, Equatable {
    var status: HealthProbeCheckStatus
    var checkedAt: Date?
    var durationMilliseconds: Int?
    var statusCode: Int?
    var detail: String

    static func notRun(_ detail: String = L10n.string("Not run yet")) -> HealthProbeCheck {
        HealthProbeCheck(
            status: .notRun,
            checkedAt: nil,
            durationMilliseconds: nil,
            statusCode: nil,
            detail: detail
        )
    }
}

struct HealthProbeSnapshot: Codable, Equatable {
    var profileID: UUID
    var profileName: String
    var trigger: String
    var startedAt: Date
    var updatedAt: Date
    var expectedExitIP: String?
    var observedExitIP: String?
    var expectedExitIPMatched: Bool?
    var expectedDNSServers: [String]?
    var reportedDNSServers: [String]
    var publicIP: HealthProbeCheck
    var dnsLeak: HealthProbeCheck
    var directHTTPS: HealthProbeCheck
    var hostnameHTTPS: HealthProbeCheck
    var resolverReachability: HealthProbeCheck
    var tunnelHandshake: HealthProbeCheck

    enum CodingKeys: String, CodingKey {
        case profileID
        case profileName
        case trigger
        case startedAt
        case updatedAt
        case expectedExitIP
        case observedExitIP
        case expectedExitIPMatched
        case expectedDNSServers
        case reportedDNSServers
        case publicIP
        case dnsLeak
        case directHTTPS
        case hostnameHTTPS
        case resolverReachability
        case tunnelHandshake
    }

    init(
        profileID: UUID,
        profileName: String,
        trigger: String,
        startedAt: Date,
        updatedAt: Date,
        expectedExitIP: String?,
        observedExitIP: String?,
        expectedExitIPMatched: Bool?,
        expectedDNSServers: [String]? = nil,
        reportedDNSServers: [String] = [],
        publicIP: HealthProbeCheck = .notRun(),
        dnsLeak: HealthProbeCheck = .notRun(),
        directHTTPS: HealthProbeCheck = .notRun(),
        hostnameHTTPS: HealthProbeCheck = .notRun(),
        resolverReachability: HealthProbeCheck = .notRun(),
        tunnelHandshake: HealthProbeCheck = .notRun()
    ) {
        self.profileID = profileID
        self.profileName = profileName
        self.trigger = trigger
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.expectedExitIP = expectedExitIP
        self.observedExitIP = observedExitIP
        self.expectedExitIPMatched = expectedExitIPMatched
        self.expectedDNSServers = expectedDNSServers
        self.reportedDNSServers = reportedDNSServers
        self.publicIP = publicIP
        self.dnsLeak = dnsLeak
        self.directHTTPS = directHTTPS
        self.hostnameHTTPS = hostnameHTTPS
        self.resolverReachability = resolverReachability
        self.tunnelHandshake = tunnelHandshake
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        profileName = try container.decode(String.self, forKey: .profileName)
        trigger = try container.decode(String.self, forKey: .trigger)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        expectedExitIP = try container.decodeIfPresent(String.self, forKey: .expectedExitIP)
        observedExitIP = try container.decodeIfPresent(String.self, forKey: .observedExitIP)
        expectedExitIPMatched = try container.decodeIfPresent(Bool.self, forKey: .expectedExitIPMatched)
        expectedDNSServers = try container.decodeIfPresent([String].self, forKey: .expectedDNSServers)
        reportedDNSServers = try container.decodeIfPresent([String].self, forKey: .reportedDNSServers) ?? []
        publicIP = try container.decodeIfPresent(HealthProbeCheck.self, forKey: .publicIP) ?? .notRun()
        dnsLeak = try container.decodeIfPresent(HealthProbeCheck.self, forKey: .dnsLeak) ?? .notRun()
        directHTTPS = try container.decodeIfPresent(HealthProbeCheck.self, forKey: .directHTTPS) ?? .notRun()
        hostnameHTTPS = try container.decodeIfPresent(HealthProbeCheck.self, forKey: .hostnameHTTPS) ?? .notRun()
        resolverReachability = try container.decodeIfPresent(HealthProbeCheck.self, forKey: .resolverReachability) ?? .notRun()
        tunnelHandshake = try container.decodeIfPresent(HealthProbeCheck.self, forKey: .tunnelHandshake) ?? .notRun()
    }
}

final class ProfileRepository {
    private static let tunnelLogTimestampFormatter = ISO8601DateFormatter()
    private let maxMasterDNSResolverCIDRHosts = 1024
    private let tunnelLogRotateAtBytes: UInt64 = 1 << 20
    private let tunnelLogKeepBytes = 128 * 1024
    private let tunnelLogLock = NSLock()
    private var tunnelLogHandle: FileHandle?
    private let fileManager: FileManager
    private let keychain: KeychainStore

    init(fileManager: FileManager = .default, keychain: KeychainStore = KeychainStore()) {
        self.fileManager = fileManager
        self.keychain = keychain
    }

    func loadProfiles() throws -> [VPNProfile] {
        let url = try profilesURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([VPNProfile].self, from: data)
    }

    func importProfile(from data: Data) throws -> VPNProfile {
        let profile = try JSONDecoder().decode(VPNProfile.self, from: data).normalizedForStorage()
        try validate(profile)

        var stored = profile
        if var settings = stored.masterdns, let key = settings.encryptionKey, !key.isEmpty {
            let reference = secretReference(for: stored.id, field: "masterdns.encryptionKey")
            try keychain.set(key, account: reference)
            settings.stripSecrets()
            settings.encryptionKeyRef = reference
            stored.masterdns = settings
        }

        var profiles = try loadProfiles()
        profiles.removeAll { $0.id == stored.id }
        profiles.append(stored)
        try saveProfiles(profiles)
        return stored
    }

    func updateProfile(_ profile: VPNProfile) throws -> VPNProfile {
        let existing = try loadProfiles().first { $0.id == profile.id }
        var updated = profile.normalizedForStorage()

        if var settings = updated.masterdns {
            if settings.encryptionKey?.isEmpty != false,
               settings.encryptionKeyRef == nil {
                settings.encryptionKeyRef = existing?.masterdns?.encryptionKeyRef
            }
            updated.masterdns = settings
        }

        _ = try resolved(updated)

        if var settings = updated.masterdns, let key = settings.encryptionKey, !key.isEmpty {
            let reference = settings.encryptionKeyRef ?? secretReference(for: updated.id, field: "masterdns.encryptionKey")
            try keychain.set(key, account: reference)
            settings.stripSecrets()
            settings.encryptionKeyRef = reference
            updated.masterdns = settings
        }

        var profiles = try loadProfiles()
        guard profiles.contains(where: { $0.id == updated.id }) else {
            throw ProfileRepositoryError.profileNotFound
        }
        profiles.removeAll { $0.id == updated.id }
        profiles.append(updated)
        try saveProfiles(profiles)
        return updated
    }

    func deleteProfile(_ profile: VPNProfile) throws {
        if let reference = profile.masterdns?.encryptionKeyRef {
            try keychain.delete(account: reference)
        }
        var profiles = try loadProfiles()
        profiles.removeAll { $0.id == profile.id }
        try saveProfiles(profiles)
    }

    func resolvedProfile(id: UUID) throws -> VPNProfile {
        guard let profile = try loadProfiles().first(where: { $0.id == id }) else {
            throw ProfileRepositoryError.profileNotFound
        }
        return try resolved(profile)
    }

    func resolved(_ profile: VPNProfile) throws -> VPNProfile {
        var resolved = profile.normalizedForStorage()
        if var settings = resolved.masterdns, settings.encryptionKey?.isEmpty ?? true {
            guard let reference = settings.encryptionKeyRef else {
                throw ProfileRepositoryError.missingSecret("masterdns.encryptionKey")
            }
            let sharedKey = try? keychain.string(for: reference)
            let key: String?
            if let sharedKey {
                key = sharedKey
            } else {
                key = try legacySecret(account: reference)
            }
            guard let key, !key.isEmpty else {
                throw ProfileRepositoryError.missingSecret(reference)
            }
            settings.injectEncryptionKey(key)
            resolved.masterdns = settings
        }
        try validate(resolved)
        return resolved
    }

    func profileJSONForTunnel(id: UUID) throws -> String {
        try profileJSONString(resolvedProfile(id: id), includeSecrets: true)
    }

    func profileJSONString(_ profile: VPNProfile, includeSecrets: Bool = false) throws -> String {
        let data = try profileJSONData(profile, includeSecrets: includeSecrets)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProfileRepositoryError.invalidProfile(L10n.string("Profile JSON encoding failed"))
        }
        return string
    }

    func profileJSONData(_ profile: VPNProfile, includeSecrets: Bool = false) throws -> Data {
        let resolved = includeSecrets ? try resolved(profile) : try exportable(profile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(resolved)
    }

    func writeSelectedProfileID(_ id: UUID) throws {
        let data = Data(id.uuidString.utf8)
        try data.write(to: selectedProfileURL(), options: .atomic)
    }

    func readSelectedProfileID() throws -> UUID? {
        let url = try selectedProfileURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let raw = try String(contentsOf: url, encoding: .utf8)
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func readTunnelLog(maxBytes: Int = 128000) throws -> String {
        let url = try tunnelLogURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return ""
        }
        var data = try Data(contentsOf: url)
        if data.count > maxBytes {
            data = data.suffix(maxBytes)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // Called for every tunnel log line, which is hundreds of times per second
    // under load, so the file handle stays open between calls and the file is
    // trimmed in place once it grows past the rotation threshold.
    func appendTunnelLog(_ line: String) throws {
        let timestamp = Self.tunnelLogTimestampFormatter.string(from: Date())
        let data = Data("\(timestamp) \(line)\n".utf8)
        let url = try tunnelLogURL()

        tunnelLogLock.lock()
        defer { tunnelLogLock.unlock() }

        if tunnelLogHandle == nil {
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                tunnelLogHandle = handle
            }
        }

        guard let handle = tunnelLogHandle else {
            try data.write(to: url, options: .atomic)
            return
        }

        do {
            try handle.write(contentsOf: data)
        } catch {
            try? handle.close()
            tunnelLogHandle = nil
            throw error
        }

        if let offset = try? handle.offset(), offset > tunnelLogRotateAtBytes {
            try? handle.close()
            tunnelLogHandle = nil
            if let existing = try? Data(contentsOf: url) {
                try? existing.suffix(tunnelLogKeepBytes).write(to: url, options: .atomic)
            }
        }
    }

    func readTunnelMetrics() throws -> TunnelMetrics? {
        let url = try tunnelMetricsURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TunnelMetrics.self, from: data)
    }

    func writeTunnelMetrics(_ metrics: TunnelMetrics) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metrics)
        try data.write(to: tunnelMetricsURL(), options: .atomic)
    }

    func readHealthProbeSnapshot() throws -> HealthProbeSnapshot? {
        let url = try healthProbeURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HealthProbeSnapshot.self, from: data)
    }

    func writeHealthProbeSnapshot(_ snapshot: HealthProbeSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        try data.write(to: healthProbeURL(), options: .atomic)
    }

    func clearTunnelLog() throws {
        let url = try tunnelLogURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }
        try fileManager.removeItem(at: url)
    }

    private func saveProfiles(_ profiles: [VPNProfile]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(profiles.sorted { $0.name < $1.name })
        try ensureSharedDirectory()
        try data.write(to: profilesURL(), options: .atomic)
    }

    private func exportable(_ profile: VPNProfile) throws -> VPNProfile {
        var copy = profile.normalizedForStorage()
        if var settings = copy.masterdns {
            settings.stripSecrets()
            copy.masterdns = settings
        }
        try validate(copy, requireSecrets: false)
        return copy
    }

    private func validate(_ profile: VPNProfile, requireSecrets: Bool = true) throws {
        if profile.version != 1 && profile.version != 2 {
            throw ProfileRepositoryError.invalidProfile(L10n.string("Unsupported profile version %d", profile.version))
        }
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileRepositoryError.invalidProfile(L10n.string("Profile name is required"))
        }
        if profile.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileRepositoryError.invalidProfile(L10n.string("Domain is required"))
        }
        if profile.resolvers.isEmpty {
            throw ProfileRepositoryError.invalidProfile(L10n.string("At least one resolver is required"))
        }
        if let expectedExitIP = profile.expectedExitIP,
           !expectedExitIP.isEmpty,
           !isValidIPAddress(expectedExitIP) {
            throw ProfileRepositoryError.invalidProfile(L10n.string("Expected exit IP must be an IPv4 or IPv6 address"))
        }
        for expectedDNSServer in profile.expectedDNSServers ?? [] where !isValidIPAddress(expectedDNSServer) {
            throw ProfileRepositoryError.invalidProfile(L10n.string("Expected DNS servers must be IPv4 or IPv6 addresses"))
        }

        switch profile.tunnelProtocol {
        case .vaydns:
            if profile.vaydns?.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                throw ProfileRepositoryError.invalidProfile(L10n.string("VayDNS public key is required"))
            }
        case .masterdns:
            try validateMasterDNSResolvers(profile.resolvers)
            try validateMasterDNSClientConfig(profile)

            if let encryptionLevel = profile.masterdns?.encryptionLevel,
               MasterDNSSettings.encryptionMethod(forLevel: encryptionLevel) == nil {
                throw ProfileRepositoryError.invalidProfile(L10n.string("Unknown MasterDnsVPN encryption level"))
            }
            let method = profile.masterdns?.encryptionMethod ?? 0
            if method < 0 || method > 5 {
                throw ProfileRepositoryError.invalidProfile(L10n.string("MasterDnsVPN encryption method must be between 0 and 5"))
            }
            if let fecLevel = profile.masterdns?.fecLevel,
               MasterDNSSettings.fecSettings(forLevel: fecLevel) == nil {
                throw ProfileRepositoryError.invalidProfile(L10n.string("Unknown MasterDnsVPN FEC level"))
            }
            if requireSecrets, profile.masterdns?.encryptionKey?.isEmpty ?? true {
                throw ProfileRepositoryError.invalidProfile(L10n.string("MasterDnsVPN encryption key is required"))
            }
        }
    }

    private func validateMasterDNSResolvers(_ resolvers: [ResolverEndpoint]) throws {
        for resolver in resolvers {
            let type = resolver.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard type == "udp" else {
                throw ProfileRepositoryError.invalidProfile(L10n.string("MasterDnsVPN iOS supports only UDP resolvers"))
            }

            let address = resolver.address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isValidIPAddressEndpoint(address) || isValidBoundedCIDREndpoint(address) else {
                throw ProfileRepositoryError.invalidProfile(L10n.string("MasterDnsVPN resolver must be an IPv4, IPv6, or bounded CIDR endpoint with an optional port"))
            }
        }
    }

    private func validateMasterDNSClientConfig(_ profile: VPNProfile) throws {
        guard let settings = profile.masterdns else {
            throw ProfileRepositoryError.invalidProfile(L10n.string("masterdns settings are required"))
        }

        let config = settings.clientConfig
        let domains = config["DOMAINS"]?.stringArrayValue ?? profile.domains
        if VPNProfile.normalizedDomains(domains).isEmpty {
            throw ProfileRepositoryError.invalidProfile(L10n.string("DOMAINS must contain at least one domain"))
        }

        let protocolType = config["PROTOCOL_TYPE"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased() ?? "SOCKS5"
        if protocolType != "SOCKS5" && protocolType != "TCP" {
            throw ProfileRepositoryError.invalidProfile(L10n.string("MasterDnsVPN PROTOCOL_TYPE must be SOCKS5 or TCP"))
        }

        let localDNSEnabled = config["LOCAL_DNS_ENABLED"]?.boolValue ?? false
        if settings.runtimeMode == .hevSocks {
            if protocolType != "SOCKS5" {
                throw ProfileRepositoryError.invalidProfile(L10n.string("Hev SOCKS mode requires MasterDnsVPN PROTOCOL_TYPE SOCKS5"))
            }
            if localDNSEnabled {
                throw ProfileRepositoryError.invalidProfile(L10n.string("Hev SOCKS mode cannot use the MasterDnsVPN local DNS listener"))
            }
        } else {
            if protocolType != "TCP" {
                throw ProfileRepositoryError.invalidProfile(L10n.string("Native Packet mode requires MasterDnsVPN PROTOCOL_TYPE TCP"))
            }
            if !localDNSEnabled {
                throw ProfileRepositoryError.invalidProfile(L10n.string("Native Packet mode requires the MasterDnsVPN local DNS listener"))
            }
        }

        try validateClientConfigInt(config, "DATA_ENCRYPTION_METHOD", min: 0, max: 5)
        try validateClientConfigInt(config, "UPLOAD_COMPRESSION_TYPE", min: 0, max: 2)
        try validateClientConfigInt(config, "DOWNLOAD_COMPRESSION_TYPE", min: 0, max: 2)
        try validateClientConfigInt(config, "COMPRESSION_MIN_SIZE", min: 0, max: 1_000_000)
        try validateClientConfigInt(config, "RESOLVER_BALANCING_STRATEGY", min: 0, max: 8)
        try validateClientConfigInt(config, "PACKET_DUPLICATION_COUNT", min: 1, max: 10)
        try validateClientConfigInt(config, "SETUP_PACKET_DUPLICATION_COUNT", min: 1, max: 12)
        try validateClientConfigInt(config, "RX_TX_WORKERS", min: 1, max: 128)
        try validateClientConfigInt(config, "TUNNEL_PROCESS_WORKERS", min: 0, max: 256)
        try validateClientConfigInt(config, "MAX_PACKETS_PER_BATCH", min: 1, max: 64)
        try validateClientConfigInt(config, "ARQ_WINDOW_SIZE", min: 1, max: 8_000)
        try validateClientConfigInt(config, "ARQ_MAX_CONTROL_RETRIES", min: 1, max: 5_000)
        try validateClientConfigInt(config, "ARQ_MAX_DATA_RETRIES", min: 1, max: 100_000)
        try validateClientConfigInt(config, "FEC_GROUP_SIZE", min: 1, max: 256)
        try validateClientConfigInt(config, "FEC_OVERHEAD_PERCENT", min: 0, max: 100)
        try validateClientConfigInt(config, "FEC_SYMBOL_SIZE", min: 0, max: 65_535)
        try validateClientConfigInt(config, "FEC_FLUSH_TIMEOUT_MS", min: 0, max: 60_000)

        let minUpload = config["MIN_UPLOAD_MTU"]?.intValue
        let maxUpload = config["MAX_UPLOAD_MTU"]?.intValue
        let minDownload = config["MIN_DOWNLOAD_MTU"]?.intValue
        let maxDownload = config["MAX_DOWNLOAD_MTU"]?.intValue
        for (key, value) in [
            ("MIN_UPLOAD_MTU", minUpload),
            ("MAX_UPLOAD_MTU", maxUpload),
            ("MIN_DOWNLOAD_MTU", minDownload),
            ("MAX_DOWNLOAD_MTU", maxDownload)
        ] where (value ?? 0) < 0 {
            throw ProfileRepositoryError.invalidProfile(L10n.string("%@ cannot be negative", key))
        }
        if let minUpload, let maxUpload, maxUpload > 0, minUpload > maxUpload {
            throw ProfileRepositoryError.invalidProfile(L10n.string("MIN_UPLOAD_MTU cannot be greater than MAX_UPLOAD_MTU"))
        }
        if let minDownload, let maxDownload, maxDownload > 0, minDownload > maxDownload {
            throw ProfileRepositoryError.invalidProfile(L10n.string("MIN_DOWNLOAD_MTU cannot be greater than MAX_DOWNLOAD_MTU"))
        }
    }

    private func validateClientConfigInt(
        _ config: [String: ProfileJSONValue],
        _ key: String,
        min: Int,
        max: Int
    ) throws {
        guard let value = config[key] else {
            return
        }
        guard let intValue = value.intValue, intValue >= min, intValue <= max else {
            throw ProfileRepositoryError.invalidProfile(
                L10n.string("%@ must be between %d and %d", key, min, max)
            )
        }
    }

    private func profilesURL() throws -> URL {
        try sharedDirectory().appendingPathComponent(AppConstants.profilesFileName, isDirectory: false)
    }

    private func selectedProfileURL() throws -> URL {
        try sharedDirectory().appendingPathComponent(AppConstants.selectedProfileFileName, isDirectory: false)
    }

    private func tunnelLogURL() throws -> URL {
        try sharedDirectory().appendingPathComponent(AppConstants.tunnelLogFileName, isDirectory: false)
    }

    private func tunnelMetricsURL() throws -> URL {
        try sharedDirectory().appendingPathComponent(AppConstants.tunnelMetricsFileName, isDirectory: false)
    }

    private func healthProbeURL() throws -> URL {
        try sharedDirectory().appendingPathComponent(AppConstants.healthProbeFileName, isDirectory: false)
    }

    private func ensureSharedDirectory() throws {
        let url = try sharedDirectory()
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func sharedDirectory() throws -> URL {
        if let url = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroupIdentifier) {
            return url
        }
        #if targetEnvironment(simulator)
        if let fallback = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            return fallback
        }
        #endif
        throw ProfileRepositoryError.sharedContainerUnavailable(AppConstants.appGroupIdentifier)
    }

    private func secretReference(for profileID: UUID, field: String) -> String {
        "profile.\(profileID.uuidString).\(field)"
    }

    private func legacySecret(account: String) throws -> String? {
        let legacyKeychain = KeychainStore(accessGroup: nil)
        guard let value = try legacyKeychain.string(for: account), !value.isEmpty else {
            return nil
        }
        try? keychain.set(value, account: account)
        return value
    }

    private func isValidIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private func isValidIPAddressEndpoint(_ value: String) -> Bool {
        let endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            return false
        }

        if isValidIPAddress(endpoint) {
            return true
        }

        if endpoint.hasPrefix("[") {
            guard let closingBracket = endpoint.firstIndex(of: "]") else {
                return false
            }

            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
            guard isValidIPAddress(host) else {
                return false
            }

            let suffix = endpoint[endpoint.index(after: closingBracket)...]
            guard !suffix.isEmpty else {
                return true
            }

            guard suffix.first == ":" else {
                return false
            }

            return isValidPort(String(suffix.dropFirst()))
        }

        let parts = endpoint.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return false
        }

        return isValidIPAddress(String(parts[0])) && isValidPort(String(parts[1]))
    }

    private func isValidBoundedCIDREndpoint(_ value: String) -> Bool {
        guard let host = endpointHost(from: value), host.contains("/") else {
            return false
        }
        return boundedCIDRHostCount(host).map { $0 <= maxMasterDNSResolverCIDRHosts } ?? false
    }

    private func endpointHost(from value: String) -> String? {
        let endpoint = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty else {
            return nil
        }

        if endpoint.hasPrefix("[") {
            guard let closingBracket = endpoint.firstIndex(of: "]") else {
                return nil
            }
            let host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
            let suffix = endpoint[endpoint.index(after: closingBracket)...]
            if suffix.isEmpty {
                return host
            }
            guard suffix.first == ":", isValidPort(String(suffix.dropFirst())) else {
                return nil
            }
            return host
        }

        if isValidIPAddress(endpoint) || boundedCIDRHostCount(endpoint) != nil {
            return endpoint
        }

        guard endpoint.filter({ $0 == ":" }).count == 1,
              let separator = endpoint.lastIndex(of: ":") else {
            return nil
        }
        let host = String(endpoint[..<separator])
        let port = String(endpoint[endpoint.index(after: separator)...])
        guard isValidPort(port) else {
            return nil
        }
        return host
    }

    private func boundedCIDRHostCount(_ value: String) -> Int? {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let bits = Int(parts[1]) else {
            return nil
        }

        let ip = String(parts[0])
        if isValidIPv4Address(ip), bits >= 0, bits <= 32 {
            let hostBits = 32 - bits
            if hostBits >= 31 {
                return hostBits == 31 ? 2 : nil
            }
            return max((1 << hostBits) - 2, 1)
        }

        if isValidIPv6Address(ip), bits >= 0, bits <= 128 {
            let hostBits = 128 - bits
            guard hostBits <= 10 else {
                return nil
            }
            let total = 1 << hostBits
            return bits < 127 ? max(total - 1, 1) : total
        }

        return nil
    }

    private func isValidIPv4Address(_ value: String) -> Bool {
        var ipv4 = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) } == 1
    }

    private func isValidIPv6Address(_ value: String) -> Bool {
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private func isValidPort(_ value: String) -> Bool {
        guard let port = Int(value), port >= 1, port <= 65535 else {
            return false
        }
        return String(port) == value
    }
}
