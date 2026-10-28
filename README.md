# Ringly for iOS

Source code of the **Ringly** iOS app — a private messenger with end-to-end encrypted messages,
photos, videos and voice/video calls.

[App Store](https://apps.apple.com/app/id6785000816) · [ringlyapp.net](https://ringlyapp.net) · [Русский ↓](#ringly-для-ios)

Each commit in this repository is the exact source of a version published in the App Store; the
commit message names the version and the build number, the tag matches the version (`v1.1`, …).
Day-to-day development happens elsewhere and is published here on every release.

## Security model in short

- **Messages, photos, videos and calls are end-to-end encrypted.** The server relays and briefly
  queues ciphertext, but never holds the keys to read it.
- Key agreement is **PQXDH** (X25519 + Kyber) via [libsignal](https://github.com/signalapp/libsignal),
  with per-device identities (multi-device, Signal-style).
- Your **name and avatar are encrypted** too; the only plaintext identifier is your `@username`.
- Calls are peer-to-peer WebRTC (DTLS-SRTP); call signaling travels as ordinary encrypted messages.
- Local history is stored in an encrypted SQLCipher database; the optional iCloud backup is encrypted
  on the device before upload.

Known, deliberate exceptions are documented in the code where they live (for example, custom ringback
tones are stored unencrypted so that a first-time caller can hear them).

## Building

Requirements: macOS with a current Xcode, [CocoaPods](https://cocoapods.org), Go (only for the
optional censorship-circumvention module).

```bash
LANG=en_US.UTF-8 pod install
./scripts/build-libxray.sh        # optional: bridges for blocked networks; without it the app builds with bridges disabled
open "ringly app.xcworkspace"
```

- **Debug** builds talk to a local backend (`RinglyCore/AppConfig.swift`), **Release** builds to
  `api.ringlyapp.net`.
- To run on a device you need your own Apple Developer team: change the bundle identifiers, the App
  Group, the iCloud container and the keychain group to ones you own (they are referenced in the
  `*.entitlements` files and in `RinglyCore/AppGroup.swift`).
- The build number is the git commit count (a build phase script), so a build from this repository
  gets a different number than the App Store build; the source is the same.
- The server is a separate project and is not part of this repository.

## Third-party components

| Component | License |
|---|---|
| [libsignal](https://github.com/signalapp/libsignal) | AGPL-3.0 |
| [GRDB.swift](https://github.com/groue/GRDB.swift) + [SQLCipher](https://www.zetetic.net/sqlcipher/) | MIT / BSD-style |
| [WebRTC](https://webrtc.org) | BSD-3-Clause |
| [libXray](https://github.com/XTLS/libXray) + [Xray-core](https://github.com/XTLS/Xray-core) | MIT / MPL-2.0 |
| Unity LevelPlay (ironSource) SDK + Unity Ads adapter — rewarded ads for Rings | proprietary, distributed by Unity under its own terms |

The ad SDKs are closed-source binaries fetched by CocoaPods; they are not part of this repository.

## Reporting a vulnerability

Please do not open a public issue — see [SECURITY.md](SECURITY.md).

## License

Copyright © 2026 Fedor Reguzov.

Licensed under the **GNU Affero General Public License v3.0** — see [LICENSE](LICENSE).

---

# Ringly для iOS

Исходный код iOS-приложения **Ringly** — мессенджера со сквозным шифрованием сообщений, фото, видео
и аудио/видеозвонков.

Каждый коммит здесь — точный исходный код версии, опубликованной в App Store: в сообщении коммита
указаны версия и номер сборки, тег совпадает с версией (`v1.1`, …). Разработка идёт отдельно и
выкладывается сюда с каждым релизом.

**Коротко о безопасности.** Сообщения, файлы и звонки шифруются на устройствах — сервер передаёт и
ненадолго хранит только шифртекст и не может его прочитать. Обмен ключами — PQXDH (X25519 + Kyber)
через libsignal, у каждого устройства свои ключи. Имя и аватар тоже зашифрованы, открыт только
`@username`. Звонки — WebRTC напрямую между собеседниками. Локальная история — в зашифрованной базе
SQLCipher, копия в iCloud шифруется до отправки.

**Сборка:** `LANG=en_US.UTF-8 pod install`, при желании `./scripts/build-libxray.sh` (мостики для
обхода блокировок), затем открыть `ringly app.xcworkspace`. Для запуска на своём устройстве нужно
заменить идентификаторы пакета, App Group, контейнер iCloud и группу Связки ключей на свои. Сервер —
отдельный проект, в репозиторий не входит.

**Уязвимости** — не в публичные задачи, а по адресу из [SECURITY.md](SECURITY.md).

**Лицензия:** GNU AGPL v3.0, см. [LICENSE](LICENSE).
