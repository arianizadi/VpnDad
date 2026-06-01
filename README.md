# VpnDad iOS

VpnDad is a SwiftUI iOS VPN client that runs DNS-tunnel engines inside a
NetworkExtension packet tunnel and bridges device traffic through a local SOCKS
adapter.

The app supports two profile protocols:

- `masterdns`: runs MasterDnsVPN through `EngineBridge.xcframework`.
- `vaydns`: runs VayDNS through the same Go engine bridge.

The protocol is selected automatically from each imported JSON profile. No app
setting is required to switch engines.

## Repository Layout

- `VpnDadApp`: SwiftUI host app for importing profiles, selecting a profile,
  exporting JSON/QR, and showing diagnostics.
- `VpnTunnelExtension`: `NEPacketTunnelProvider` extension that starts the Go
  engine and packet-flow SOCKS bridge.
- `Shared`: profile schema, App Group storage, metrics, logs, and
  Keychain-backed secret storage.
- `scripts`: local build scripts for generated native frameworks.
- `profiles`: sanitized examples only. Real profiles are ignored by Git.

## Required Generated Frameworks

The Xcode project references these generated frameworks:

- `Vendor/EngineBridge.xcframework`
- `Vendor/HevSocks5Tunnel.xcframework`

They are intentionally not committed. Build them locally before opening or
building the Xcode project:

```sh
scripts/build_engine_bridge.sh
scripts/build_hev_socks5_tunnel.sh
```

`EngineBridge.xcframework` is built from the sibling
`../MasterDnsVPN/mobilebridge` package. Use the custom
`arianizadi/MasterDnsVPN` fork when you want the mobile bridge diagnostics and
optional download FEC support.

## MasterDnsVPN Compatibility

VpnDad works with normal MasterDnsVPN servers when the profile uses
`protocol: "masterdns"` and FEC is disabled or omitted. The app sends the normal
MasterDnsVPN session setup and the tunnel behaves like standard ARQ.

The custom `arianizadi/MasterDnsVPN` build adds:

- the `mobilebridge` package required by this app build,
- engine status/diagnostics exported to the iOS UI,
- optional download-side RaptorQ FEC.

FEC is negotiated after session accept with `PACKET_SESSION_CAPS`. If the server
does not support it, does not ACK it, or has FEC disabled, the app automatically
falls back to standard ARQ. That means a profile can keep FEC disabled for a
normal server, or enable it for the custom server without breaking older
servers.

## Build

From the repository root:

```sh
scripts/build_engine_bridge.sh
scripts/build_hev_socks5_tunnel.sh
xcodebuild \
  -project VpnDadApp.xcodeproj \
  -scheme VpnDad \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/VpnDadDerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For device builds, configure your own bundle IDs, App Group, signing team, and
Network Extension entitlement in Xcode.

Default identifiers in this working copy:

- App bundle: `com.arianizadi.vpndad`
- Extension bundle: `com.arianizadi.vpndad.tunnel`
- App Group: `group.com.arianizadi.vpndad.vpn`
- Shared Keychain group: `$(AppIdentifierPrefix)com.arianizadi.vpndad`

## Profiles

Profiles are JSON files imported by the app. The host app stores shared secrets
in Keychain when possible and keeps only references in the App Group profile
store.

Example files:

- `profiles/masterdns-normal.example.json`: normal MasterDnsVPN server, no FEC.
- `profiles/masterdns-custom-fec.example.json`: custom MasterDnsVPN server with
  optional download FEC enabled.
- `profiles/vaydns.example.json`: VayDNS tunnel profile.

Replace all placeholder domains, resolver IPs, public keys, and encryption keys
before importing.

Real profiles such as `profiles/masterdns-devbox.json` are ignored because they
can contain endpoints and shared keys.

## MasterDnsVPN Profile Fields

```json
{
  "version": 1,
  "name": "Example MasterDNS",
  "protocol": "masterdns",
  "domain": "dns-tunnel.example.com",
  "resolvers": [{"type": "udp", "address": "203.0.113.10:53"}],
  "masterdns": {
    "encryptionKey": "replace-with-shared-secret",
    "encryptionLevel": "maximum",
    "baseEncodeData": false
  }
}
```

`encryptionLevel` can be `standard` (AES-128-GCM, method `3`), `strong`
(AES-192-GCM, method `4`), or `maximum` (AES-256-GCM, method `5`). You can
also use the raw `encryptionMethod` field directly. The app defaults to
`maximum`; the MasterDnsVPN server must use the matching encryption method.

Optional FEC preset:

```json
{
  "fecLevel": "balanced"
}
```

`fecLevel` can be `none`, `conservative`, `balanced`, or `aggressive`.
`conservative` matches the original custom FEC defaults: group size `8`, repair
overhead `15%`, auto symbol size, and `25ms` flush. `balanced` requests group
size `12`, overhead `25%`, and `20ms` flush. `aggressive` requests group size
`16`, overhead `40%`, and `15ms` flush. The server must also enable FEC and can
clamp these values; otherwise the app continues with normal ARQ.

Advanced profiles can still use the raw FEC fields instead of `fecLevel`:
`fecEnabled`, `fecDirection`, `fecGroupSize`, `fecOverheadPercent`,
`fecSymbolSize`, and `fecFlushTimeoutMs`.

## Security Notes

- Do not commit real profiles, shared keys, provisioning profiles, certificates,
  or private keys.
- The `.gitignore` keeps generated frameworks and real profile JSON files out of
  Git.
- Commit only sanitized `*.example.json` profiles.
