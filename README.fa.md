# VpnDad iOS

VpnDad یک برنامه VPN برای iPhone است که برای آزمایش پروفایل های DNS tunnel با
پروتکل های `masterdns` و `vaydns` ساخته شده و مسیر کار آن ساده است: import،
connect و health check.

**زبان ها:** [English](README.md) | [Русский](README.ru.md) |
[فارسی](README.fa.md)

## شروع سریع

اگر در حال تست برنامه هستید و profile JSON را دارید، این مراحل را انجام دهید.

1. آخرین release asset با نام `VpnDad-*-unsigned.ipa` را از GitHub دانلود کنید.
2. از Sideloadly برای sign و install کردن IPA روی iPhone استفاده کنید.
3. VpnDad را باز کنید، روی `Import` بزنید و VpnDad profile JSON را انتخاب کنید.
4. profile وارد شده را انتخاب کنید، روی `Connect` بزنید و اجازه VPN را تایید
   کنید.
5. در بخش `Health`، روی `Run All Checks` بزنید. اگر چیزی fail شد، روی
   `Export Diagnostics` بزنید و JSON را برای developer بفرستید.

برای profileهای MasterDnsVPN، mode پیشنهادی `nativePacket` با
`PROTOCOL_TYPE` برابر `TCP` است. فقط وقتی developer مشخصا legacy SOCKS bridge
path را خواست، از `hevSocks` به عنوان fallback استفاده کنید.

فایل `VpnDad-*-unsigned.ipa` روی iOS معمولی مستقیم قابل نصب نیست. اول باید
re-sign شود، و Sideloadly همین کار را روی کامپیوتر تست کننده انجام می دهد.

## چیزهایی که لازم دارید

- یک iPhone برای تست.
- Sideloadly نصب شده روی macOS یا Windows.
- Apple account یا signing identity که بتواند برنامه را sign و install کند.
- آخرین فایل `VpnDad-*-unsigned.ipa`.
- VpnDad profile JSON از developer.

## اگر نصب ناموفق بود

- اگر Sideloadly قبل از نصب خطا داد، signing setup و کامل بودن دانلود IPA را
  بررسی کنید.
- اگر برنامه نصب شد ولی VPN شروع نشد، اول entitlements را بررسی کنید. VpnDad
  شامل Packet Tunnel Network Extension است، بنابراین app و extension امضا شده
  باید Network Extension، App Group و Keychain access entitlements معتبر داشته
  باشند.
- اگر Sideloadly برای signing setup شما کار نکرد، از
  [WarpSign](https://github.com/teflocarbon/warpsign) استفاده کنید. WarpSign یک
  مسیر command-line پیشرفته تر برای signing است، پس setup instructions خود آن
  را دنبال کنید.

## VpnDad چه کار می کند

VpnDad یک profile JSON را import می کند، iOS Packet Tunnel را راه می اندازد،
DNS tunnel engine انتخاب شده را اجرا می کند، و health checks و diagnostics قابل
اشتراک گذاری نشان می دهد.

برنامه از دو profile protocol پشتیبانی می کند:

- `masterdns`: MasterDnsVPN را از طریق `EngineBridge.xcframework` اجرا می کند.
- `vaydns`: VayDNS را از طریق همان Go engine bridge اجرا می کند.

Protocol به صورت خودکار از هر JSON profile وارد شده انتخاب می شود. برای تغییر
engine به تنظیم جداگانه در برنامه نیاز نیست.

## زبان های برنامه

رابط کاربری برنامه برای این زبان ها localize شده است:

- English (`en`)
- Russian (`ru`)
- Farsi/Persian (`fa`)

iOS زبان را از preferred language settings دستگاه انتخاب می کند. مقادیر
profile وارد شده، raw tunnel logs، exported JSON، domains، IP addresses و
protocol names عمدا همان طور که هستند نمایش داده می شوند تا diagnostics قابل
کپی باشند و با داده های profile/server مطابقت داشته باشند.

## برای توسعه دهندگان

### ساختار repository

- `VpnDadApp`: SwiftUI host app برای import کردن profiles، انتخاب profile،
  export کردن JSON/QR و نمایش diagnostics.
- `VpnTunnelExtension`: `NEPacketTunnelProvider` extension که Go engine و
  packet-flow SOCKS bridge را شروع می کند.
- `Shared`: profile schema، App Group storage، metrics، logs و Keychain-backed
  secret storage.
- `scripts`: build scripts محلی برای generated native frameworks.
- `profiles`: فقط sanitized examples. Real profiles توسط Git نادیده گرفته می
  شوند.

### Generated frameworks لازم

پروژه Xcode به این generated frameworks اشاره می کند:

- `Vendor/EngineBridge.xcframework`
- `Vendor/HevSocks5Tunnel.xcframework`

این فایل ها عمدا commit نشده اند. قبل از باز کردن یا build کردن پروژه Xcode،
آن ها را local بسازید:

```sh
scripts/build_engine_bridge.sh
scripts/build_hev_socks5_tunnel.sh
```

`EngineBridge.xcframework` از sibling package یعنی
`../MasterDnsVPN/mobilebridge` ساخته می شود. برای همین package و mobile bridge
diagnostics از custom fork `arianizadi/MasterDnsVPN` استفاده کنید. FEC support
جدا، فقط برای custom build، و برای normal testing باید خاموش بماند.

### ساخت Xcode

از root repository:

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

برای device builds، bundle IDs، App Group، signing team و Network Extension
entitlement خودتان را در Xcode تنظیم کنید.

Default identifiers در این working copy:

- App bundle: `com.arianizadi.vpndad`
- Extension bundle: `com.arianizadi.vpndad.tunnel`
- App Group: `group.com.arianizadi.vpndad.vpn`
- Shared Keychain group: `$(AppIdentifierPrefix)com.arianizadi.vpndad`

### Release workflow برای unsigned IPA

GitHub Actions فقط وقتی stable tag push شود، unsigned IPA را build و publish می
کند. Matching tag patterns:

- `stable-*`, for example `stable-1.0.0`
- `stable/**`, for example `stable/v1.0.0`
- `v*-stable`, for example `v1.0.0-stable`
- `v*-stable.*`, for example `v1.0.0-stable.1`

یک stable tag بسازید و push کنید:

```sh
git tag stable-1.0.0
git push origin stable-1.0.0
```

Workflow این app، custom fork `arianizadi/MasterDnsVPN`، و sibling dependencies
یعنی `vaydns` و `raptorq` را check out می کند. سپس generated XCFrameworks را
دوباره build می کند، `VpnDad.app` را برای `iphoneos` با disabled code signing
می سازد، `Payload/VpnDad.app` را package می کند، artifact با نامی مثل
`VpnDad-stable-1.0.0-unsigned.ipa` را upload می کند، و همان IPA را در matching
GitHub release هم upload می کند.

چون VpnDad شامل packet tunnel extension است، final signer همچنان باید برای app،
extension، App Group، Keychain access group و Network Extension capability
دارای valid entitlements باشد.

### Profiles

Profiles همان JSON files هستند که برنامه import می کند. Host app تا جای ممکن
shared secrets را در Keychain نگه می دارد و فقط references را در App Group
profile store ذخیره می کند.

Example files:

- `profiles/masterdns-normal.example.json`: recommended native packet TCP
  MasterDnsVPN server, no FEC.
- `profiles/masterdns-custom-fec.example.json`: custom forked native packet TCP
  MasterDnsVPN server with experimental download FEC enabled.
- `profiles/vaydns.example.json`: VayDNS tunnel profile.

قبل از import، همه placeholder domains، resolver IPs، public keys و encryption
keys را جایگزین کنید.

Real profiles مثل `profiles/masterdns-devbox.json` نادیده گرفته می شوند، چون
ممکن است endpoints و shared keys داشته باشند.

### MasterDnsVPN profile fields

```json
{
  "version": 1,
  "name": "Example MasterDNS",
  "protocol": "masterdns",
  "domain": "dns-tunnel.example.com",
  "domains": ["dns-tunnel.example.com"],
  "resolvers": [{"type": "udp", "address": "203.0.113.10:53"}],
  "masterdns": {
    "runtimeMode": "nativePacket",
    "clientConfig": {
      "PROTOCOL_TYPE": "TCP",
      "DOMAINS": ["dns-tunnel.example.com"],
      "LOCAL_DNS_ENABLED": true,
      "DATA_ENCRYPTION_METHOD": 5,
      "ENCRYPTION_KEY": "replace-with-shared-secret",
      "BASE_ENCODE_DATA": false
    }
  }
}
```

`masterdns.clientConfig` همان uppercase keys مربوط به desktop client JSON/TOML
config در MasterDnsVPN را استفاده می کند. Legacy fields مثل `encryptionKey`،
`encryptionMethod`، `encryptionLevel`، `baseEncodeData` و FEC shortcuts همچنان
import می شوند؛ canonical keys جاافتاده از همین aliases پر می شوند.

`runtimeMode` مسیر iOS transport را کنترل می کند:

- `nativePacket`: برای normal MasterDnsVPN testing توصیه می شود. به
  `PROTOCOL_TYPE` `TCP` و `LOCAL_DNS_ENABLED` `true` نیاز دارد. Tunnel
  extension، IP packets را از `NEPacketTunnelFlow` به Go gVisor netstack
  adapter می دهد. TCP flows و DNS UDP/53 از MasterDnsVPN stream و DNS-cache
  paths استفاده می کنند؛ generic non-DNS UDP منتقل نمی شود.
- `hevSocks`: legacy fallback. به `PROTOCOL_TYPE` `SOCKS5` و
  `LOCAL_DNS_ENABLED` `false` نیاز دارد.

`DATA_ENCRYPTION_METHOD` از desktop bounds یعنی `0` تا `5` پیروی می کند. Editor
برای legacy methods کمتر از `3` warning می دهد؛ AES-GCM methods `3`، `4` و
`5` همچنان recommended choices برای iOS testing هستند.

Resolverهای MasterDnsVPN باید `"type": "udp"` و یک IPv4 یا IPv6 address با port
اختیاری داشته باشند. چند UDP IP resolver در imported JSON و editor پشتیبانی
می شود، یک endpoint در هر خط.

### VayDNS profile fields

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

Optional health-check expectations را می توان با `expectedExitIP` و
`expectedDNSServers` به هر profile type اضافه کرد.

### MasterDnsVPN Support Matrix

در حال حاضر VpnDad دو MasterDnsVPN runtime mode دارد:

- پیشنهادی: `nativePacket` با `PROTOCOL_TYPE` `TCP`.
- `hevSocks`: iOS Packet Tunnel -> HevSocks5Tunnel -> local SOCKS5 ->
  MasterDnsVPN `mobilebridge`.
- `nativePacket`: iOS Packet Tunnel -> Go gVisor packet adapter ->
  MasterDnsVPN runtime بدون local listener sockets.

مواردی که فعلا پشتیبانی می شوند:

- Profileهای `protocol: "masterdns"`.
- Full desktop client config storage زیر `masterdns.clientConfig`.
- Legacy MasterDnsVPN aliases به canonical `clientConfig` keys import می شوند.
- SOCKS5 server mode از طریق mobile bridge در `hevSocks` runtime mode.
- Native packet mode برای MasterDnsVPN TCP flows و DNS UDP/53.
- Desktop encryption method bounds از `0` تا `5`، همراه با iOS warnings برای
  legacy non-AES-GCM methods.
- `BASE_ENCODE_DATA`، compression، MTU، resolver strategy، duplication،
  worker/timer، ARQ، FEC و logging fields در editor.
- Multiple domains و UDP IP/CIDR resolvers در imported JSON و editor.
- Keychain-only MasterDnsVPN secret persistence و secret-free profile export.
- Custom-fork FEC fields، experimental و به صورت پیش فرض collapsed در editor.
- Engine diagnostics و metrics در iOS UI.

مواردی که فعلا پشتیبانی نمی شوند:

- Non-UDP MasterDnsVPN resolvers.
- Hostname، DoH یا DoT resolverهای MasterDnsVPN.
- Generic non-DNS UDP through native packet mode.
- Server config generation.

Custom build یعنی `arianizadi/MasterDnsVPN` package `mobilebridge` لازم برای
build این app و engine status/diagnostics قابل export در iOS UI را اضافه می کند.

### Experimental FEC (فقط custom fork)

FEC خارج از mobile subset پشتیبانی شده MasterDnsVPN است. این فقط برای custom
implementation یعنی `arianizadi/MasterDnsVPN` است که این app می تواند با آن
build شود.

من فعال کردن FEC را برای normal testing توصیه نمی کنم. این قابلیت experimental
است و می تواند باعث VPN disconnections شود. اگر عمدا FEC behavior در custom
fork را تست نمی کنید، `fecLevel` را حذف کنید، روی `none` بگذارید، یا
`fecEnabled` را false نگه دارید.

FEC بعد از session accept با `PACKET_SESSION_CAPS` negotiated می شود. اگر server
از آن پشتیبانی نکند، ACK ندهد یا FEC خاموش باشد، app خودکار به standard ARQ
برمی گردد. یعنی یک profile می تواند FEC را برای normal server خاموش نگه دارد،
یا برای custom server روشن کند، بدون اینکه older servers خراب شوند.

Optional FEC preset:

```json
{
  "fecLevel": "balanced"
}
```

`fecLevel` می تواند `none`، `conservative`، `balanced` یا `aggressive` باشد.
`conservative` با original custom FEC defaults همخوان است: group size `8`،
repair overhead `15%`، auto symbol size و `25ms` flush. `balanced` مقدار group
size `12`، overhead `25%` و `20ms` flush را درخواست می کند. `aggressive` مقدار
group size `16`، overhead `40%` و `15ms` flush را درخواست می کند. Server هم باید
FEC را enable کند و می تواند این مقدارها را clamp کند؛ در غیر این صورت app با
normal ARQ ادامه می دهد.

Advanced profiles همچنان می توانند به جای `fecLevel` از raw FEC fields استفاده
کنند: `fecEnabled`، `fecDirection`، `fecGroupSize`، `fecOverheadPercent`،
`fecSymbolSize` و `fecFlushTimeoutMs`.

### نکات امنیتی

- Real profiles، shared keys، provisioning profiles، certificates یا private
  keys را commit نکنید.
- `.gitignore` باعث می شود generated frameworks و real profile JSON files وارد
  Git نشوند.
- فقط sanitized `*.example.json` profiles را commit کنید.
