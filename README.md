# Lumen Legacy

The **iOS 12 – 15** client for [Lumen](https://github.com/cheapearth9/Lumen): low-latency screen streaming from a Mac, Windows PC or
Linux PC to an iPhone/iPad over Wi-Fi or a USB cable, with touch, mouse, keyboard and controller input going back, audio, end-to-end
encryption and external display output. It speaks the exact same wire protocol as the main app, so it works with the same hosts.

It is a UIKit-only port of the main app (which needs iOS 16 because it is SwiftUI + CryptoKit based). It also runs on iOS 16 and later,
but there the [main app](https://github.com/cheapearth9/Lumen/releases) is the better choice.

## Supported systems

* **iOS / iPadOS 12.0 or later.** iOS 10 and 11 are not possible: HEVC decoding through VideoToolbox / `AVSampleBufferDisplayLayer` needs
  iOS 11, and the app relies on the Security framework APIs for P-256 key agreement (`SecKeyCopyKeyExchangeResult`, iOS 10+) together with
  Network.framework (`NWConnection` / `NWListener`, iOS 12+).
* **Hardware HEVC decoding requires an A9 chip or newer**: iPhone 6s / SE / 7 and newer, iPad (5th generation) and newer, every iPad Pro,
  iPad Air (3rd generation) and newer, iPad mini (5th generation) and newer. Older devices (iPhone 5s / 6, iPad Air 1 / 2, iPad mini 2 - 4)
  can install the app but **cannot decode the stream** until an H.264 mode is added to the hosts.

## Install (sideload)

Download `Lumen-Legacy.ipa` from the [Releases](../../releases) tab. It is **unsigned**; install it with AltStore, Sideloadly, TrollStore or
re-sign it yourself. Bundle id `com.lumen.legacy`, display name "Lumen Legacy". It can be installed next to the main Lumen app.

## Hosts

The Mac / Windows / Linux hosts are **not** in this repository. Get them from the main Lumen releases:
<https://github.com/cheapearth9/Lumen/releases>. Start the host, open Lumen Legacy, pick the computer (or plug in the USB cable) and type the
5-digit pairing code on the computer the first time you connect.

## Differences from the main app

| | Lumen | Lumen Legacy |
|---|---|---|
| UI | SwiftUI | UIKit only (table-view screens, action-sheet stream menu instead of `UIMenu`) |
| Crypto | CryptoKit | CommonCrypto + Security. SHA-256, HMAC, HKDF built on `CCHmac`; ECDH P-256 with `SecKey`; **AES-256-GCM implemented in `Shared/Crypto.swift`** (CTR from AES-ECB + GHASH). Packet layout is byte-identical |
| Bonjour | `NWBrowser` | `NetServiceBrowser` (`NWBrowser` is iOS 13+); the unicast subnet scan is the same |
| Audio | `AVAudioSourceNode` | RemoteIO audio unit (`AVAudioSourceNode` is iOS 13+) |
| Hardware keyboard | GameController | iOS 14+: `GCKeyboard`; iOS 13.4: `UIPress.key`; iOS 12 / 13.0 - 13.3: `UIKeyCommand` strokes (no key-up events, shifted symbols are best effort) |
| Hardware mouse / pointer lock | GCMouse + pointer lock | only on iOS 14+ (hover pointer position on iOS 13+) |
| Controllers | GameController | same (`extendedGamepad`); on iOS 12 the Start button comes from the pause handler and Options / Guide are not available |
| External display | scene based | `UIScreen.didConnectNotification` + a `UIWindow` on the external screen (the app has no scene manifest, so this works on every iOS version) |

Features are otherwise the same: Bonjour + subnet-scan discovery, manual IP, recents, pairing (5-digit code in an alert), HEVC video,
audio, touchpad and touchscreen modes (native multi-touch on Windows / Linux hosts), soft keyboard, controllers (XInput mapping),
Mirror / Extend, resolution (Full screen / 16:9 1080p / Custom), frame rate, separate Cable (up to 150 Mbps) and Wi-Fi (up to 80 Mbps)
bitrate sliders, and USB cable mode (the app listens on TCP 47901, packets are u32-BE length framed).

## Build

No Xcode project is checked in; it is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project LumenLegacy.xcodeproj -scheme LumenLegacy -configuration Release -sdk iphoneos \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

The deployment target is iOS 12.0 (Swift 5). Use an Xcode that still allows it (Xcode 16.x); the CI uses `macos-15`.
`Tools/SelfTest` compiles `Shared/Crypto.swift` on the Mac and checks AES-GCM, HKDF and ECDH against CryptoKit (CI runs it before building).
The app also runs the known-answer tests (NIST GCM vectors, RFC 5869 / 4231) at launch.

## Releases

Every push to `main` (except Markdown-only changes) builds the unsigned `Lumen-Legacy.ipa` and publishes a GitHub release. First release
is `1.0`; a bug-fix push bumps the last number (`1.0` -> `1.0.1`); a head-commit message containing `[major]` bumps the middle number
with rollover after `.9` (`1.9` -> `2.0`).
