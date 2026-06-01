import Foundation

enum TunnelRuntimeError: LocalizedError {
    case missingEngineBridge
    case missingHevSocks5Tunnel
    case hevIntegrationNotConfigured(String)
    case missingProfile
    case engineHandshakeFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingEngineBridge:
            return "EngineBridge.xcframework is not embedded"
        case .missingHevSocks5Tunnel:
            return "HevSocks5Tunnel.xcframework is not embedded"
        case .hevIntegrationNotConfigured(let reason):
            return "HevSocks5Tunnel adapter is not configured: \(reason)"
        case .missingProfile:
            return "VPN profile was not provided"
        case .engineHandshakeFailed(let detail):
            return "MasterDnsVPN handshake failed: \(detail)"
        }
    }
}
