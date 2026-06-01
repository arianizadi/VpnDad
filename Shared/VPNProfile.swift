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
    var encryptionMethod: Int
    var baseEncodeData: Bool
    var fecEnabled: Bool
    var fecDirection: String
    var fecGroupSize: Int
    var fecOverheadPercent: Int
    var fecSymbolSize: Int
    var fecFlushTimeoutMs: Int

    enum CodingKeys: String, CodingKey {
        case encryptionKey
        case encryptionKeyRef
        case encryptionMethod
        case baseEncodeData
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
        encryptionMethod: Int = 5,
        baseEncodeData: Bool = false,
        fecEnabled: Bool = false,
        fecDirection: String = "download",
        fecGroupSize: Int = 8,
        fecOverheadPercent: Int = 15,
        fecSymbolSize: Int = 0,
        fecFlushTimeoutMs: Int = 25
    ) {
        self.encryptionKey = encryptionKey
        self.encryptionKeyRef = encryptionKeyRef
        self.encryptionMethod = encryptionMethod
        self.baseEncodeData = baseEncodeData
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
        encryptionMethod = try container.decodeIfPresent(Int.self, forKey: .encryptionMethod) ?? 5
        baseEncodeData = try container.decodeIfPresent(Bool.self, forKey: .baseEncodeData) ?? false
        fecEnabled = try container.decodeIfPresent(Bool.self, forKey: .fecEnabled) ?? false
        fecDirection = try container.decodeIfPresent(String.self, forKey: .fecDirection) ?? "download"
        fecGroupSize = try container.decodeIfPresent(Int.self, forKey: .fecGroupSize) ?? 8
        fecOverheadPercent = try container.decodeIfPresent(Int.self, forKey: .fecOverheadPercent) ?? 15
        fecSymbolSize = try container.decodeIfPresent(Int.self, forKey: .fecSymbolSize) ?? 0
        fecFlushTimeoutMs = try container.decodeIfPresent(Int.self, forKey: .fecFlushTimeoutMs) ?? 25
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
        if copy.masterdns?.encryptionMethod == 0 {
            copy.masterdns?.encryptionMethod = 5
        }
        if copy.masterdns?.fecDirection.isEmpty == true {
            copy.masterdns?.fecDirection = "download"
        }
        if copy.masterdns?.fecGroupSize == 0 {
            copy.masterdns?.fecGroupSize = 8
        }
        if copy.masterdns?.fecOverheadPercent == 0 {
            copy.masterdns?.fecOverheadPercent = 15
        }
        if copy.masterdns?.fecFlushTimeoutMs == 0 {
            copy.masterdns?.fecFlushTimeoutMs = 25
        }
        return copy
    }
}
