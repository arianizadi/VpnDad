# VpnDad iOS

VpnDad is an iPhone VPN app for testing `masterdns` and `vaydns` DNS tunnel
profiles with a simple import, connect, and health-check flow.

**Languages:** [English](README.md) | [Русский](README.ru.md) |
[فارسی](README.fa.md)

## Quick Start

Use these steps if you are testing the app and already have a profile JSON.

1. Download the latest `VpnDad-*-unsigned.ipa` release asset from GitHub.
2. Use Sideloadly to sign and install the IPA on the iPhone.
3. Open VpnDad, tap `Import`, and choose the VpnDad profile JSON.
4. Select the imported profile, tap `Connect`, and approve the VPN permission.
5. In the `Health` section, tap `Run All Checks`. If something fails, tap
   `Export Diagnostics` and send the JSON to the developer.

The `VpnDad-*-unsigned.ipa` file is not directly installable on stock iOS. It
must be re-signed first, which is what Sideloadly does on the tester's machine.

## What You Need

- An iPhone for testing.
- Sideloadly installed on macOS or Windows.
- An Apple account or signing identity that can sign and install the app.
- The latest `VpnDad-*-unsigned.ipa` file.
- A VpnDad profile JSON from the developer.

## If Install Fails

- If Sideloadly fails before install, check the signing setup and that the IPA
  download completed.
- If the app installs but the VPN cannot start, check entitlements first. VpnDad
  contains a Packet Tunnel Network Extension, so the signed app and extension
  need valid Network Extension, App Group, and Keychain access entitlements.
- If Sideloadly does not work for your signing setup, try
  [WarpSign](https://github.com/teflocarbon/warpsign). WarpSign is a more
  advanced command-line signing path, so follow its own setup instructions.

## What VpnDad Does

VpnDad imports a profile JSON, starts an iOS Packet Tunnel, runs the selected DNS
tunnel engine, and shows health checks and diagnostics that are easy to share.

The app supports two profile protocols:

- `masterdns`: runs MasterDnsVPN through `EngineBridge.xcframework`.
- `vaydns`: runs VayDNS through the same Go engine bridge.

The protocol is selected automatically from each imported JSON profile. No app
setting is required to switch engines.

## App Languages

The app UI is localized for:

- English (`en`)
- Russian (`ru`)
- Farsi/Persian (`fa`)

iOS selects the language from the device's preferred language settings. Imported
profile values, raw tunnel logs, exported JSON, domains, IP addresses, and
protocol names are intentionally shown as-is so diagnostics stay copyable and
match the underlying profile/server data.

## For Developers

### Repository Layout

- `VpnDadApp`: SwiftUI host app for importing profiles, selecting a profile,
  exporting JSON/QR, and showing diagnostics.
- `VpnTunnelExtension`: `NEPacketTunnelProvider` extension that starts the Go
  engine and packet-flow SOCKS bridge.
- `Shared`: profile schema, App Group storage, metrics, logs, and
  Keychain-backed secret storage.
- `scripts`: local build scripts for generated native frameworks.
- `profiles`: sanitized examples only. Real profiles are ignored by Git.

### Required Generated Frameworks

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
`arianizadi/MasterDnsVPN` fork when you want the mobile bridge diagnostics. FEC
support is separate, custom-only, and should stay off for normal testing.

### Xcode Build

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

### Unsigned IPA Release Workflow

GitHub Actions builds and publishes an unsigned IPA only when a stable tag is
pushed. Matching tag patterns are:

- `stable-*`, for example `stable-1.0.0`
- `stable/**`, for example `stable/v1.0.0`
- `v*-stable`, for example `v1.0.0-stable`
- `v*-stable.*`, for example `v1.0.0-stable.1`

Create and push a stable tag:

```sh
git tag stable-1.0.0
git push origin stable-1.0.0
```

The workflow checks out this app, the custom `arianizadi/MasterDnsVPN` fork, and
the sibling `vaydns` and `raptorq` dependencies. It rebuilds the generated
XCFrameworks, builds `VpnDad.app` for `iphoneos` with code signing disabled,
packages `Payload/VpnDad.app`, uploads an artifact named like
`VpnDad-stable-1.0.0-unsigned.ipa`, and uploads the same IPA to the matching
GitHub release.

Because VpnDad includes a packet tunnel extension, the final signer still needs
valid entitlements for the app, the extension, the App Group, Keychain access
group, and Network Extension capability.

### Profiles

Profiles are JSON files imported by the app. The host app stores shared secrets
in Keychain when possible and keeps only references in the App Group profile
store.

Example files:

- `profiles/masterdns-normal.example.json`: normal MasterDnsVPN server, no FEC.
- `profiles/masterdns-custom-fec.example.json`: custom forked MasterDnsVPN
  server with experimental download FEC enabled.
- `profiles/vaydns.example.json`: VayDNS tunnel profile.

Replace all placeholder domains, resolver IPs, public keys, and encryption keys
before importing.

Real profiles such as `profiles/masterdns-devbox.json` are ignored because they
can contain endpoints and shared keys.

### MasterDnsVPN Profile Fields

```json
{
  "version": 1,
  "name": "Example MasterDNS",
  "protocol": "masterdns",
  "domain": "dns-tunnel.example.com",
  "domains": ["dns-tunnel.example.com"],
  "resolvers": [{"type": "udp", "address": "203.0.113.10:53"}],
  "masterdns": {
    "runtimeMode": "hevSocks",
    "clientConfig": {
      "PROTOCOL_TYPE": "SOCKS5",
      "DOMAINS": ["dns-tunnel.example.com"],
      "LOCAL_DNS_ENABLED": false,
      "DATA_ENCRYPTION_METHOD": 5,
      "ENCRYPTION_KEY": "replace-with-shared-secret",
      "BASE_ENCODE_DATA": false
    }
  }
}
```

`masterdns.clientConfig` uses the same uppercase keys as the MasterDnsVPN
desktop client JSON/TOML config. Legacy fields such as `encryptionKey`,
`encryptionMethod`, `encryptionLevel`, `baseEncodeData`, and the FEC shortcuts
still import; missing canonical keys are filled from those aliases.

`runtimeMode` controls the iOS transport:

- `hevSocks`: stable default. Requires `PROTOCOL_TYPE` `SOCKS5` and
  `LOCAL_DNS_ENABLED` `false`.
- `nativePacket`: experimental packet runtime for TCP mode and local DNS.
  The tunnel extension feeds `NEPacketTunnelFlow` IP packets into the Go gVisor
  netstack adapter. TCP flows and DNS UDP/53 use the MasterDnsVPN stream and
  DNS-cache paths; generic non-DNS UDP is not carried.

`domains` and `clientConfig.DOMAINS` can contain multiple tunnel domains.
`domain` remains the first display domain for older profile compatibility.

`DATA_ENCRYPTION_METHOD` follows desktop bounds `0` through `5`. The editor
warns on legacy methods below `3`; AES-GCM methods `3`, `4`, and `5` remain the
recommended choices for iOS testing.

MasterDnsVPN resolvers must use `"type": "udp"` and an IPv4 or IPv6 address
with an optional port. Small CIDR ranges are accepted for MasterDnsVPN resolver
expansion and route exclusion; oversized ranges are rejected. Hostname, DoH, and
DoT MasterDnsVPN resolvers are still rejected.

When a profile is imported, `encryptionKey` or `clientConfig.ENCRYPTION_KEY` is
stored in Keychain and removed from the App Group profile store. Exported JSON
and QR payloads do not include `ENCRYPTION_KEY`; the tunnel extension receives a
resolved in-memory JSON payload with the key only at launch time.

### VayDNS Profile Fields

```json
{
  "version": 1,
  "name": "Example VayDNS",
  "protocol": "vaydns",
  "domain": "dns-tunnel.example.com",
  "resolvers": [{"type": "udp", "address": "203.0.113.10:53"}],
  "vaydns": {
    "publicKey": "replace-with-server-public-key",
    "recordType": "txt",
    "maxQnameLen": 101
  }
}
```

Optional health-check expectations can be added to either profile type with
`expectedExitIP` and `expectedDNSServers`.

### MasterDnsVPN Support Matrix

VpnDad currently has two MasterDnsVPN runtime modes:

- `hevSocks`: iOS Packet Tunnel -> HevSocks5Tunnel -> local SOCKS5 ->
  MasterDnsVPN `mobilebridge`.
- `nativePacket`: iOS Packet Tunnel -> Go gVisor packet adapter ->
  MasterDnsVPN runtime without local listener sockets.

Supported now:

- `protocol: "masterdns"` profiles.
- Full desktop client config storage under `masterdns.clientConfig`.
- Legacy MasterDnsVPN aliases imported into canonical `clientConfig` keys.
- SOCKS5 server mode through the mobile bridge in `hevSocks` runtime mode.
- Native packet mode for MasterDnsVPN TCP flows and DNS UDP/53.
- `hevSocks` runtime clamps MasterDnsVPN packet duplication to `1x` for iOS
  upload stability, even if the imported desktop profile asks for more.
- Desktop encryption method bounds `0` through `5`, with iOS warnings for
  legacy non-AES-GCM methods.
- `BASE_ENCODE_DATA`, compression, MTU, resolver strategy, duplication,
  worker/timer, ARQ, FEC, and logging fields in the editor.
- Multiple domains and UDP IP/CIDR resolvers in imported JSON and the editor.
- Keychain-only MasterDnsVPN secret persistence and secret-free profile export.
- Custom-fork FEC fields, experimental and collapsed by default in the editor.
- Engine diagnostics and metrics in the iOS UI.

Not supported now:

- Non-UDP MasterDnsVPN resolvers.
- Hostname, DoH, or DoT MasterDnsVPN resolvers.
- Generic non-DNS UDP through native packet mode.
- Server config generation.

The custom `arianizadi/MasterDnsVPN` build adds the `mobilebridge` package
required by this app build and engine status/diagnostics exported to the iOS UI.

### Experimental FEC (Custom Fork Only)

FEC is outside the supported mobile MasterDnsVPN subset. It only applies to the
custom `arianizadi/MasterDnsVPN` implementation that this app can build against.

I do not recommend enabling FEC for normal testing. It is experimental and can
cause VPN disconnections. Leave `fecLevel` omitted, set to `none`, or keep
`fecEnabled` false unless you are intentionally testing the custom fork's FEC
behavior.

FEC is negotiated after session accept with `PACKET_SESSION_CAPS`. If the server
does not support it, does not ACK it, or has FEC disabled, the app automatically
falls back to standard ARQ. That means a profile can keep FEC disabled for a
normal server, or enable it for the custom server without breaking older
servers.

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

### Security Notes

- Do not commit real profiles, shared keys, provisioning profiles, certificates,
  or private keys.
- The `.gitignore` keeps generated frameworks and real profile JSON files out of
  Git.
- Commit only sanitized `*.example.json` profiles.
