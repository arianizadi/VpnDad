import Foundation

enum TunnelProtocol: String, Codable, CaseIterable, Identifiable {
    case vaydns
    case masterdns

    var id: String { rawValue }
}

enum MasterDNSRuntimeMode: String, Codable, CaseIterable, Identifiable {
    case hevSocks
    case nativePacket

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hevSocks:
            return "Hev SOCKS"
        case .nativePacket:
            return "Native Packet"
        }
    }
}

enum ProfileJSONValue: Codable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([ProfileJSONValue])
    case object([String: ProfileJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([ProfileJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: ProfileJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let value):
            return value
        case .int(let value):
            return "\(value)"
        case .double(let value):
            return "\(value)"
        case .bool(let value):
            return value ? "true" : "false"
        default:
            return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value):
            return value
        case .double(let value) where value.rounded() == value:
            return Int(value)
        case .string(let value):
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let value):
            return value
        case .int(let value):
            return Double(value)
        case .string(let value):
            return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value):
            return value
        case .string(let value):
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes", "on":
                return true
            case "false", "0", "no", "off":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    var stringArrayValue: [String]? {
        switch self {
        case .array(let values):
            return values.compactMap(\.stringValue)
        case .string(let value):
            return [value]
        default:
            return nil
        }
    }
}

struct ResolverEndpoint: Codable, Hashable {
    var type: String
    var address: String
}

struct VayDNSSettings: Codable, Hashable {
    var publicKey: String
    var recordType: String
    var maxQnameLen: Int

    init(publicKey: String, recordType: String = "txt", maxQnameLen: Int = 101) {
        self.publicKey = publicKey
        self.recordType = recordType
        self.maxQnameLen = maxQnameLen
    }
}

struct MasterDNSSettings: Codable, Hashable {
    var runtimeMode: MasterDNSRuntimeMode
    var clientConfig: [String: ProfileJSONValue]
    var encryptionKey: String?
    var encryptionKeyRef: String?
    var encryptionLevel: String?
    var encryptionMethod: Int
    var baseEncodeData: Bool
    var fecLevel: String?
    var fecEnabled: Bool
    var fecDirection: String
    var fecGroupSize: Int
    var fecOverheadPercent: Int
    var fecSymbolSize: Int
    var fecFlushTimeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case runtimeMode
        case clientConfig
        case encryptionKey
        case encryptionKeyRef
        case encryptionLevel
        case encryptionMethod
        case baseEncodeData
        case fecLevel
        case fecEnabled
        case fecDirection
        case fecGroupSize
        case fecOverheadPercent
        case fecSymbolSize
        case fecFlushTimeoutMs
    }

    init(
        runtimeMode: MasterDNSRuntimeMode = .hevSocks,
        clientConfig: [String: ProfileJSONValue] = [:],
        encryptionKey: String? = nil,
        encryptionKeyRef: String? = nil,
        encryptionLevel: String? = nil,
        encryptionMethod: Int = 5,
        baseEncodeData: Bool = false,
        fecLevel: String? = nil,
        fecEnabled: Bool = false,
        fecDirection: String = "download",
        fecGroupSize: Int = 8,
        fecOverheadPercent: Int = 15,
        fecSymbolSize: Int = 0,
        fecFlushTimeoutMs: Int = 25
    ) {
        self.runtimeMode = runtimeMode
        self.clientConfig = clientConfig
        self.encryptionKey = encryptionKey
        self.encryptionKeyRef = encryptionKeyRef
        self.encryptionLevel = encryptionLevel
        self.encryptionMethod = encryptionMethod
        self.baseEncodeData = baseEncodeData
        self.fecLevel = fecLevel
        self.fecEnabled = fecEnabled
        self.fecDirection = fecDirection
        self.fecGroupSize = fecGroupSize
        self.fecOverheadPercent = fecOverheadPercent
        self.fecSymbolSize = fecSymbolSize
        self.fecFlushTimeoutMs = fecFlushTimeoutMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtimeMode = try container.decodeIfPresent(MasterDNSRuntimeMode.self, forKey: .runtimeMode) ?? .hevSocks
        clientConfig = try container.decodeIfPresent([String: ProfileJSONValue].self, forKey: .clientConfig) ?? [:]
        encryptionKey = try container.decodeIfPresent(String.self, forKey: .encryptionKey)
        encryptionKeyRef = try container.decodeIfPresent(String.self, forKey: .encryptionKeyRef)
        let decodedEncryptionLevel = try container.decodeIfPresent(String.self, forKey: .encryptionLevel)
        let decodedEncryptionMethod = try container.decodeIfPresent(Int.self, forKey: .encryptionMethod)
        if let method = decodedEncryptionMethod,
           let levelMethod = MasterDNSSettings.encryptionMethod(forLevel: decodedEncryptionLevel),
           method != levelMethod {
            throw DecodingError.dataCorruptedError(
                forKey: .encryptionMethod,
                in: container,
                debugDescription: "encryptionMethod conflicts with encryptionLevel"
            )
        }
        encryptionLevel = decodedEncryptionLevel
        encryptionMethod = decodedEncryptionMethod ?? 5
        baseEncodeData = try container.decodeIfPresent(Bool.self, forKey: .baseEncodeData) ?? false
        fecLevel = try container.decodeIfPresent(String.self, forKey: .fecLevel)
        fecEnabled = try container.decodeIfPresent(Bool.self, forKey: .fecEnabled) ?? false
        fecDirection = try container.decodeIfPresent(String.self, forKey: .fecDirection) ?? "download"
        fecGroupSize = try container.decodeIfPresent(Int.self, forKey: .fecGroupSize) ?? 8
        fecOverheadPercent = try container.decodeIfPresent(Int.self, forKey: .fecOverheadPercent) ?? 15
        fecSymbolSize = try container.decodeIfPresent(Int.self, forKey: .fecSymbolSize) ?? 0
        fecFlushTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .fecFlushTimeoutMs) ?? 25
    }

    mutating func normalizeClientConfig(fallbackDomains: [String]) -> [String] {
        var normalizedClientConfig: [String: ProfileJSONValue] = [:]
        for (key, value) in clientConfig {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard !normalizedKey.isEmpty else {
                continue
            }
            normalizedClientConfig[normalizedKey] = value
        }
        clientConfig = normalizedClientConfig

        let canonicalDomains = VPNProfile.normalizedDomains(
            clientConfig["DOMAINS"]?.stringArrayValue ?? fallbackDomains
        )
        if !canonicalDomains.isEmpty {
            clientConfig["DOMAINS"] = .array(canonicalDomains.map { .string($0) })
        }

        let defaultProtocolType = runtimeMode == .nativePacket ? "TCP" : "SOCKS5"
        let configuredProtocolType = clientConfig["PROTOCOL_TYPE"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if runtimeMode == .nativePacket {
            clientConfig["PROTOCOL_TYPE"] = .string("TCP")
        } else {
            clientConfig["PROTOCOL_TYPE"] = .string(configuredProtocolType ?? defaultProtocolType)
        }

        if runtimeMode == .nativePacket {
            clientConfig["LOCAL_DNS_ENABLED"] = .bool(true)
        } else if clientConfig["LOCAL_DNS_ENABLED"] == nil {
            clientConfig["LOCAL_DNS_ENABLED"] = .bool(false)
        }

        if let method = clientConfig["DATA_ENCRYPTION_METHOD"]?.intValue {
            encryptionMethod = method
        } else {
            clientConfig["DATA_ENCRYPTION_METHOD"] = .int(encryptionMethod)
        }

        if let baseEncode = clientConfig["BASE_ENCODE_DATA"]?.boolValue {
            baseEncodeData = baseEncode
        } else {
            clientConfig["BASE_ENCODE_DATA"] = .bool(baseEncodeData)
        }

        if let key = clientConfig["ENCRYPTION_KEY"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty,
           encryptionKey?.isEmpty ?? true {
            encryptionKey = key
        } else if clientConfig["ENCRYPTION_KEY"] == nil,
                  let key = encryptionKey?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty {
            clientConfig["ENCRYPTION_KEY"] = .string(key)
        }

        if let fecConfigLevel = clientConfig["FEC_LEVEL"]?.stringValue {
            fecLevel = fecConfigLevel
        } else if let fecLevel {
            clientConfig["FEC_LEVEL"] = .string(fecLevel)
        }
        if let enabled = clientConfig["FEC_ENABLED"]?.boolValue {
            fecEnabled = enabled
        } else {
            clientConfig["FEC_ENABLED"] = .bool(fecEnabled)
        }
        if let direction = clientConfig["FEC_DIRECTION"]?.stringValue, !direction.isEmpty {
            fecDirection = direction
        } else {
            clientConfig["FEC_DIRECTION"] = .string(fecDirection)
        }
        fecGroupSize = normalizedFECIntConfig("FEC_GROUP_SIZE", fallback: fecGroupSize)
        fecOverheadPercent = normalizedFECIntConfig("FEC_OVERHEAD_PERCENT", fallback: fecOverheadPercent)
        fecSymbolSize = normalizedFECIntConfig("FEC_SYMBOL_SIZE", fallback: fecSymbolSize)
        fecFlushTimeoutMs = normalizedFECIntConfig("FEC_FLUSH_TIMEOUT_MS", fallback: fecFlushTimeoutMs)

        return canonicalDomains
    }

    mutating func stripSecrets() {
        encryptionKey = nil
        clientConfig.removeValue(forKey: "ENCRYPTION_KEY")
    }

    mutating func injectEncryptionKey(_ key: String) {
        encryptionKey = key
        clientConfig["ENCRYPTION_KEY"] = .string(key)
    }

    private mutating func normalizedFECIntConfig(_ key: String, fallback: Int) -> Int {
        if let configured = clientConfig[key]?.intValue {
            return configured
        }
        clientConfig[key] = .int(fallback)
        return fallback
    }

    static func normalizedEncryptionLevel(_ level: String?) -> String? {
        guard var normalized = level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        normalized = normalized
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        switch normalized {
        case "standard", "aes-128", "aes-128-gcm", "aes128", "aes128-gcm", "128":
            return "standard"
        case "strong", "aes-192", "aes-192-gcm", "aes192", "aes192-gcm", "192":
            return "strong"
        case "maximum", "max", "strongest", "aes-256", "aes-256-gcm", "aes256", "aes256-gcm", "256":
            return "maximum"
        default:
            return normalized
        }
    }

    static func encryptionMethod(forLevel level: String?) -> Int? {
        switch normalizedEncryptionLevel(level) {
        case "standard":
            return 3
        case "strong":
            return 4
        case "maximum":
            return 5
        default:
            return nil
        }
    }

    static func normalizedFECLevel(_ level: String?) -> String? {
        guard var normalized = level?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else {
            return nil
        }
        normalized = normalized.replacingOccurrences(of: "_", with: "-")
        switch normalized {
        case "off", "disabled", "disable":
            return "none"
        case "safe", "low":
            return "conservative"
        case "medium":
            return "balanced"
        case "high":
            return "aggressive"
        default:
            return normalized
        }
    }

    static func fecSettings(forLevel level: String?) -> (
        level: String,
        enabled: Bool,
        groupSize: Int,
        overheadPercent: Int,
        symbolSize: Int,
        flushTimeoutMs: Int
    )? {
        switch normalizedFECLevel(level) {
        case "none":
            return ("none", false, 8, 15, 0, 25)
        case "conservative":
            return ("conservative", true, 8, 15, 0, 25)
        case "balanced":
            return ("balanced", true, 12, 25, 0, 20)
        case "aggressive":
            return ("aggressive", true, 16, 40, 0, 15)
        default:
            return nil
        }
    }
}

struct VPNProfile: Codable, Identifiable, Hashable {
    static let iosForceHevSocksClientConfigKey = "IOS_FORCE_HEV_SOCKS"

    var id: UUID
    var version: Int
    var name: String
    var tunnelProtocol: TunnelProtocol
    var domain: String
    var domains: [String]
    var resolvers: [ResolverEndpoint]
    var expectedExitIP: String?
    var expectedDNSServers: [String]?
    var vaydns: VayDNSSettings?
    var masterdns: MasterDNSSettings?

    enum CodingKeys: String, CodingKey {
        case id
        case version
        case name
        case tunnelProtocol = "protocol"
        case domain
        case domains
        case resolvers
        case expectedExitIP
        case expectedDNSServers
        case vaydns
        case masterdns
    }

    init(
        id: UUID = UUID(),
        version: Int = 1,
        name: String,
        tunnelProtocol: TunnelProtocol,
        domain: String,
        domains: [String]? = nil,
        resolvers: [ResolverEndpoint],
        expectedExitIP: String? = nil,
        expectedDNSServers: [String]? = nil,
        vaydns: VayDNSSettings? = nil,
        masterdns: MasterDNSSettings? = nil
    ) {
        self.id = id
        self.version = version
        self.name = name
        self.tunnelProtocol = tunnelProtocol
        self.domain = domain
        self.domains = domains ?? [domain]
        self.resolvers = resolvers
        self.expectedExitIP = expectedExitIP
        self.expectedDNSServers = expectedDNSServers
        self.vaydns = vaydns
        self.masterdns = masterdns
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        version = try container.decode(Int.self, forKey: .version)
        name = try container.decode(String.self, forKey: .name)
        tunnelProtocol = try container.decode(TunnelProtocol.self, forKey: .tunnelProtocol)
        domain = try container.decode(String.self, forKey: .domain)
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? [domain]
        resolvers = try container.decode([ResolverEndpoint].self, forKey: .resolvers)
        expectedExitIP = try container.decodeIfPresent(String.self, forKey: .expectedExitIP)
        expectedDNSServers = try container.decodeIfPresent([String].self, forKey: .expectedDNSServers)
        vaydns = try container.decodeIfPresent(VayDNSSettings.self, forKey: .vaydns)
        masterdns = try container.decodeIfPresent(MasterDNSSettings.self, forKey: .masterdns)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(tunnelProtocol, forKey: .tunnelProtocol)
        try container.encode(domain, forKey: .domain)
        if tunnelProtocol == .masterdns || domains != [domain] {
            try container.encode(domains, forKey: .domains)
        }
        try container.encode(resolvers, forKey: .resolvers)
        try container.encodeIfPresent(expectedExitIP, forKey: .expectedExitIP)
        try container.encodeIfPresent(expectedDNSServers, forKey: .expectedDNSServers)
        try container.encodeIfPresent(vaydns, forKey: .vaydns)
        try container.encodeIfPresent(masterdns, forKey: .masterdns)
    }

    func normalizedForStorage() -> VPNProfile {
        var copy = self
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.domain = copy.domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        copy.domains = Self.normalizedDomains(copy.domains.isEmpty ? [copy.domain] : copy.domains)
        if copy.domains.isEmpty, !copy.domain.isEmpty {
            copy.domains = [copy.domain]
        }
        if copy.tunnelProtocol == .vaydns {
            copy.domains = copy.domain.isEmpty ? [] : [copy.domain]
        }
        copy.resolvers = copy.resolvers.map {
            ResolverEndpoint(
                type: $0.type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                address: $0.address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        copy.expectedExitIP = copy.expectedExitIP?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.expectedExitIP?.isEmpty == true {
            copy.expectedExitIP = nil
        }
        copy.expectedDNSServers = copy.expectedDNSServers?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if copy.expectedDNSServers?.isEmpty == true {
            copy.expectedDNSServers = nil
        }
        if copy.vaydns?.recordType.isEmpty == true {
            copy.vaydns?.recordType = "txt"
        }
        if copy.vaydns?.maxQnameLen == 0 {
            copy.vaydns?.maxQnameLen = 101
        }
        if var settings = copy.masterdns {
            settings.encryptionLevel = MasterDNSSettings.normalizedEncryptionLevel(settings.encryptionLevel)
            if let method = MasterDNSSettings.encryptionMethod(forLevel: settings.encryptionLevel) {
                settings.encryptionMethod = method
            } else if settings.encryptionMethod == 0 {
                settings.encryptionMethod = 5
            }

            settings.fecLevel = MasterDNSSettings.normalizedFECLevel(settings.fecLevel)
            if let fecPreset = MasterDNSSettings.fecSettings(forLevel: settings.fecLevel) {
                settings.fecLevel = fecPreset.level
                settings.fecEnabled = fecPreset.enabled
                settings.fecDirection = "download"
                settings.fecGroupSize = fecPreset.groupSize
                settings.fecOverheadPercent = fecPreset.overheadPercent
                settings.fecSymbolSize = fecPreset.symbolSize
                settings.fecFlushTimeoutMs = fecPreset.flushTimeoutMs
            } else {
                if settings.fecDirection.isEmpty {
                    settings.fecDirection = "download"
                }
                if settings.fecGroupSize == 0 {
                    settings.fecGroupSize = 8
                }
                if settings.fecOverheadPercent == 0 {
                    settings.fecOverheadPercent = 15
                }
                if settings.fecFlushTimeoutMs == 0 {
                    settings.fecFlushTimeoutMs = 25
                }
            }
            let domains = settings.normalizeClientConfig(fallbackDomains: copy.domains.isEmpty ? [copy.domain] : copy.domains)
            if !domains.isEmpty {
                copy.domains = domains
                copy.domain = domains[0]
            }
            copy.masterdns = settings
        }
        return copy
    }

    func preparedForIOSTunnelStart() -> (
        profile: VPNProfile,
        runtimeMode: MasterDNSRuntimeMode,
        runtimeModeSource: String
    ) {
        guard tunnelProtocol == .masterdns else {
            return (normalizedForStorage(), .hevSocks, "non-masterdns")
        }

        var copy = normalizedForStorage()
        guard var settings = copy.masterdns else {
            return (copy, .hevSocks, "missing-masterdns-settings")
        }

        if settings.runtimeMode == .hevSocks {
            settings.clientConfig["PROTOCOL_TYPE"] = .string("SOCKS5")
            settings.clientConfig["LOCAL_DNS_ENABLED"] = .bool(false)
            settings.clientConfig[Self.iosForceHevSocksClientConfigKey] = .bool(true)
            copy.masterdns = settings
            return (copy.normalizedForStorage(), .hevSocks, "profile-hev-socks")
        }

        settings.runtimeMode = .nativePacket
        settings.clientConfig[Self.iosForceHevSocksClientConfigKey] = .bool(false)
        settings.clientConfig["PROTOCOL_TYPE"] = .string("TCP")
        settings.clientConfig["LOCAL_DNS_ENABLED"] = .bool(true)
        copy.masterdns = settings
        return (copy.normalizedForStorage(), .nativePacket, "profile-native")
    }

    static func normalizedDomains(_ domains: [String]) -> [String] {
        var seen = Set<String>()
        return domains.compactMap { raw in
            let domain = raw
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !domain.isEmpty, seen.insert(domain).inserted else {
                return nil
            }
            return domain
        }
    }
}
