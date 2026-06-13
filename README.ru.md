# VpnDad iOS

VpnDad - это приложение VPN для iPhone, предназначенное для тестирования DNS
туннельных профилей `masterdns` и `vaydns` через простой сценарий: импортировать
профиль, подключиться и запустить проверки.

**Языки:** [English](README.md) | [Русский](README.ru.md) |
[فارسی](README.fa.md)

## Быстрый старт

Используйте эти шаги, если вы тестируете приложение и у вас уже есть профиль
JSON.

1. Скачайте последний release asset `VpnDad-*-unsigned.ipa` из GitHub.
2. Используйте Sideloadly, чтобы sign и install IPA на iPhone.
3. Откройте VpnDad, нажмите `Import` и выберите VpnDad profile JSON.
4. Выберите импортированный профиль, нажмите `Connect` и разрешите VPN.
5. В разделе `Health` нажмите `Run All Checks`. Если что-то не прошло проверку,
   нажмите `Export Diagnostics` и отправьте JSON разработчику.

Файл `VpnDad-*-unsigned.ipa` нельзя напрямую установить на обычную iOS. Сначала
его нужно re-sign, и именно это Sideloadly делает на компьютере тестировщика.

## Что понадобится

- iPhone для тестирования.
- Sideloadly, установленный на macOS или Windows.
- Apple account или signing identity, который может sign и install приложение.
- Последний файл `VpnDad-*-unsigned.ipa`.
- VpnDad profile JSON от разработчика.

## Если установка не работает

- Если Sideloadly падает до установки, проверьте signing setup и то, что IPA
  скачался полностью.
- Если приложение установилось, но VPN не запускается, сначала проверьте
  entitlements. VpnDad содержит Packet Tunnel Network Extension, поэтому
  подписанным приложению и extension нужны действительные Network Extension,
  App Group и Keychain access entitlements.
- Если Sideloadly не подходит для вашей signing setup, попробуйте
  [WarpSign](https://github.com/teflocarbon/warpsign). WarpSign - более
  продвинутый command-line способ подписи, поэтому следуйте его собственным
  setup instructions.

## Что делает VpnDad

VpnDad импортирует profile JSON, запускает iOS Packet Tunnel, включает выбранный
DNS tunnel engine и показывает health checks и diagnostics, которыми легко
поделиться.

Приложение поддерживает два протокола профилей:

- `masterdns`: запускает MasterDnsVPN через `EngineBridge.xcframework`.
- `vaydns`: запускает VayDNS через тот же Go engine bridge.

Протокол выбирается автоматически из каждого импортированного JSON profile. Для
переключения engines не нужна отдельная настройка в приложении.

## Языки приложения

Интерфейс приложения локализован для:

- English (`en`)
- Russian (`ru`)
- Farsi/Persian (`fa`)

iOS выбирает язык по preferred language settings устройства. Значения из
импортированных профилей, raw tunnel logs, exported JSON, domains, IP addresses
и protocol names намеренно показываются как есть, чтобы diagnostics можно было
копировать и сверять с данными профиля или сервера.

## Для разработчиков

### Структура репозитория

- `VpnDadApp`: SwiftUI host app для импорта профилей, выбора профиля, экспорта
  JSON/QR и показа diagnostics.
- `VpnTunnelExtension`: `NEPacketTunnelProvider` extension, который запускает Go
  engine и packet-flow SOCKS bridge.
- `Shared`: profile schema, App Group storage, metrics, logs и
  Keychain-backed secret storage.
- `scripts`: локальные build scripts для generated native frameworks.
- `profiles`: только sanitized examples. Real profiles игнорируются Git.

### Обязательные generated frameworks

Проект Xcode ссылается на эти generated frameworks:

- `Vendor/EngineBridge.xcframework`
- `Vendor/HevSocks5Tunnel.xcframework`

Они намеренно не коммитятся. Соберите их локально перед открытием или сборкой
проекта Xcode:

```sh
scripts/build_engine_bridge.sh
scripts/build_hev_socks5_tunnel.sh
```

`EngineBridge.xcframework` собирается из sibling package
`../MasterDnsVPN/mobilebridge`. Используйте custom fork
`arianizadi/MasterDnsVPN`, когда нужны mobile bridge diagnostics. FEC support
отдельный, только для custom build, и для normal testing должен оставаться
выключенным.

### Сборка в Xcode

Из корня репозитория:

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

Для device builds настройте свои bundle IDs, App Group, signing team и Network
Extension entitlement в Xcode.

Default identifiers в этой рабочей копии:

- App bundle: `com.arianizadi.vpndad`
- Extension bundle: `com.arianizadi.vpndad.tunnel`
- App Group: `group.com.arianizadi.vpndad.vpn`
- Shared Keychain group: `$(AppIdentifierPrefix)com.arianizadi.vpndad`

### Release workflow для unsigned IPA

GitHub Actions собирает и публикует unsigned IPA только когда pushed stable tag.
Подходящие tag patterns:

- `stable-*`, for example `stable-1.0.0`
- `stable/**`, for example `stable/v1.0.0`
- `v*-stable`, for example `v1.0.0-stable`
- `v*-stable.*`, for example `v1.0.0-stable.1`

Создайте и отправьте stable tag:

```sh
git tag stable-1.0.0
git push origin stable-1.0.0
```

Workflow checks out это приложение, custom fork `arianizadi/MasterDnsVPN`, а
также sibling dependencies `vaydns` и `raptorq`. Он пересобирает generated
XCFrameworks, собирает `VpnDad.app` для `iphoneos` с disabled code signing,
упаковывает `Payload/VpnDad.app`, загружает artifact с именем вроде
`VpnDad-stable-1.0.0-unsigned.ipa` и загружает тот же IPA в matching GitHub
release.

Так как VpnDad включает packet tunnel extension, final signer все равно должен
иметь valid entitlements для app, extension, App Group, Keychain access group и
Network Extension capability.

### Профили

Profiles - это JSON files, импортируемые приложением. Host app по возможности
хранит shared secrets в Keychain и оставляет только references в App Group
profile store.

Примеры файлов:

- `profiles/masterdns-normal.example.json`: normal MasterDnsVPN server, no FEC.
- `profiles/masterdns-custom-fec.example.json`: custom forked MasterDnsVPN
  server with experimental download FEC enabled.
- `profiles/vaydns.example.json`: VayDNS tunnel profile.

Перед импортом замените все placeholder domains, resolver IPs, public keys и
encryption keys.

Real profiles, например `profiles/masterdns-devbox.json`, игнорируются, потому
что могут содержать endpoints и shared keys.

### Поля профиля MasterDnsVPN

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

`encryptionLevel` может быть `standard` (AES-128-GCM, method `3`), `strong`
(AES-192-GCM, method `4`) или `maximum` (AES-256-GCM, method `5`). Также можно
использовать raw field `encryptionMethod` напрямую. По умолчанию приложение
использует `maximum`; сервер MasterDnsVPN должен использовать matching
encryption method.

Резолверы MasterDnsVPN должны использовать `"type": "udp"` и IPv4- или
IPv6-адрес с необязательным портом. Несколько UDP IP-резолверов поддерживаются
в импортированном JSON и в редакторе, по одному endpoint в строке.

### Поля профиля VayDNS

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

Optional health-check expectations можно добавить к любому типу профиля через
`expectedExitIP` и `expectedDNSServers`.

### MasterDnsVPN Support Matrix

Сейчас VpnDad поддерживает mobile subset MasterDnsVPN через такой путь:
iOS Packet Tunnel -> HevSocks5Tunnel -> local SOCKS5 ->
MasterDnsVPN `mobilebridge`.

Поддерживается сейчас:

- Profiles с `protocol: "masterdns"`.
- SOCKS5 server mode через mobile bridge.
- AES-GCM encryption methods `3`, `4` и `5` через `encryptionMethod` или
  `encryptionLevel`.
- `baseEncodeData`.
- Несколько UDP IP-резолверов в импортированном JSON и редакторе.
- Custom-fork FEC fields, только experimental.
- Engine diagnostics и metrics в iOS UI.

Не поддерживается сейчас:

- MasterDnsVPN TCP mode.
- MasterDnsVPN local DNS listener/cache.
- Non-UDP MasterDnsVPN resolvers.
- Hostname, DoH или DoT MasterDnsVPN resolvers.
- Server config generation.
- Полные desktop knobs для compression, MTU, resolver strategy, packet
  duplication, worker/timer tuning или ARQ tuning.

Полный desktop/client parity MasterDnsVPN требует отдельной packet/stream
architecture rewrite за пределами текущего Hev SOCKS bridge.

Custom build `arianizadi/MasterDnsVPN` добавляет package `mobilebridge`, нужный
для сборки этого приложения, и engine status/diagnostics, экспортируемые в iOS
UI.

### Experimental FEC (только custom fork)

FEC находится вне поддерживаемого mobile subset MasterDnsVPN. Он относится
только к custom implementation `arianizadi/MasterDnsVPN`, с которой это
приложение может собираться.

Я не рекомендую включать FEC для normal testing. Это experimental feature, и она
может вызывать VPN disconnections. Оставьте `fecLevel` неуказанным, задайте
`none` или держите `fecEnabled` false, если вы не тестируете FEC behavior в
custom fork намеренно.

FEC negotiated после session accept через `PACKET_SESSION_CAPS`. Если сервер не
поддерживает это, не отправляет ACK или FEC выключен, приложение автоматически
возвращается к standard ARQ. Это значит, что профиль может держать FEC
выключенным для normal server или включить его для custom server без поломки
старых серверов.

Optional FEC preset:

```json
{
  "fecLevel": "balanced"
}
```

`fecLevel` может быть `none`, `conservative`, `balanced` или `aggressive`.
`conservative` соответствует original custom FEC defaults: group size `8`,
repair overhead `15%`, auto symbol size и `25ms` flush. `balanced` запрашивает
group size `12`, overhead `25%` и `20ms` flush. `aggressive` запрашивает group
size `16`, overhead `40%` и `15ms` flush. Сервер тоже должен включить FEC и
может clamp эти значения; иначе приложение продолжит работу с normal ARQ.

Advanced profiles могут использовать raw FEC fields вместо `fecLevel`:
`fecEnabled`, `fecDirection`, `fecGroupSize`, `fecOverheadPercent`,
`fecSymbolSize` и `fecFlushTimeoutMs`.

### Заметки по безопасности

- Не коммитьте real profiles, shared keys, provisioning profiles, certificates
  или private keys.
- `.gitignore` держит generated frameworks и real profile JSON files вне Git.
- Коммитьте только sanitized `*.example.json` profiles.
