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
            return "Profile was not found"
        case .missingSecret(let key):
            return "Missing profile secret: \(key)"
        case .invalidProfile(let reason):
            return reason
        case .sharedContainerUnavailable(let identifier):
            return "App Group container is unavailable: \(identifier)"
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

    static func notRun(_ detail: String = "Not run yet") -> HealthProbeCheck {
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
            settings.encryptionKey = nil
            settings.encryptionKeyRef = reference
            stored.masterdns = settings
        }

        var profiles = try loadProfiles()
        profiles.removeAll { $0.id == stored.id }
        profiles.append(stored)
        try saveProfiles(profiles)
        return stored
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
            settings.encryptionKey = key
            resolved.masterdns = settings
        }
        try validate(resolved)
        return resolved
    }

    func profileJSONForTunnel(id: UUID) throws -> String {
        try profileJSONString(resolvedProfile(id: id))
    }

    func profileJSONString(_ profile: VPNProfile) throws -> String {
        let data = try profileJSONData(profile)
        guard let string = String(data: data, encoding: .utf8) else {
            throw ProfileRepositoryError.invalidProfile("Profile JSON encoding failed")
        }
        return string
    }

    func profileJSONData(_ profile: VPNProfile) throws -> Data {
        let resolved = try resolved(profile)
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

    func readTunnelLog(maxBytes: Int = 12000) throws -> String {
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

    func appendTunnelLog(_ line: String) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let text = "\(timestamp) \(line)\n"
        let url = try tunnelLogURL()
        let data = Data(text.utf8)

        if fileManager.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: .atomic)
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

    private func validate(_ profile: VPNProfile) throws {
        if profile.version != 1 {
            throw ProfileRepositoryError.invalidProfile("Unsupported profile version \(profile.version)")
        }
        if profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileRepositoryError.invalidProfile("Profile name is required")
        }
        if profile.domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProfileRepositoryError.invalidProfile("Domain is required")
        }
        if profile.resolvers.isEmpty {
            throw ProfileRepositoryError.invalidProfile("At least one resolver is required")
        }
        if let expectedExitIP = profile.expectedExitIP,
           !expectedExitIP.isEmpty,
           !isValidIPAddress(expectedExitIP) {
            throw ProfileRepositoryError.invalidProfile("Expected exit IP must be an IPv4 or IPv6 address")
        }
        for expectedDNSServer in profile.expectedDNSServers ?? [] where !isValidIPAddress(expectedDNSServer) {
            throw ProfileRepositoryError.invalidProfile("Expected DNS servers must be IPv4 or IPv6 addresses")
        }

        switch profile.tunnelProtocol {
        case .vaydns:
            if profile.vaydns?.publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                throw ProfileRepositoryError.invalidProfile("VayDNS public key is required")
            }
        case .masterdns:
            let method = profile.masterdns?.encryptionMethod ?? 0
            if method < 3 || method > 5 {
                throw ProfileRepositoryError.invalidProfile("MasterDnsVPN requires AES-GCM encryption")
            }
            if profile.masterdns?.encryptionKey?.isEmpty ?? true {
                throw ProfileRepositoryError.invalidProfile("MasterDnsVPN encryption key is required")
            }
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
}
