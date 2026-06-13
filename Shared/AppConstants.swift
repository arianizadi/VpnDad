import Foundation

enum AppConstants {
    static let appGroupIdentifier = "group.com.arianizadi.vpndad.vpn"
    static let tunnelBundleIdentifier = "com.arianizadi.vpndad.tunnel"
    static let keychainService = "com.arianizadi.vpndad.profile-secrets"
    #if targetEnvironment(simulator)
    static let keychainAccessGroup: String? = nil
    #else
    static let keychainAccessGroup: String? = "76572UUM5Z.com.arianizadi.vpndad"
    #endif
    static let profilesFileName = "profiles.json"
    static let selectedProfileFileName = "selected-profile.json"
    static let tunnelLogFileName = "tunnel.log"
    static let tunnelMetricsFileName = "tunnel-metrics.json"
    static let healthProbeFileName = "health-probe.json"
    static let advancedModeDefaultsKey = "advancedModeEnabled"
    static let defaultSocksAddress = "127.0.0.1:18080"
    static let tunnelIPv4Address = "198.18.0.1"
    static let fakeDNSAddress = "198.18.0.2"
    static let tunnelIPv6Address = "fd7a:7670:6e64::1"
}
