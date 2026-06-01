import Foundation

enum TunnelProtocol: String, Codable, CaseIterable, Identifiable {
    case vaydns
    case masterdns

    var id: String { rawValue }
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
    var id: UUID
    var version: Int
    var name: String
    var tunnelProtocol: TunnelProtocol
    var domain: String
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
        resolvers = try container.decode([ResolverEndpoint].self, forKey: .resolvers)
        expectedExitIP = try container.decodeIfPresent(String.self, forKey: .expectedExitIP)
        expectedDNSServers = try container.decodeIfPresent([String].self, forKey: .expectedDNSServers)
        vaydns = try container.decodeIfPresent(VayDNSSettings.self, forKey: .vaydns)
        masterdns = try container.decodeIfPresent(MasterDNSSettings.self, forKey: .masterdns)
    }

    func normalizedForStorage() -> VPNProfile {
        var copy = self
        copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.domain = copy.domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
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
            copy.masterdns = settings
        }
        return copy
    }
}
