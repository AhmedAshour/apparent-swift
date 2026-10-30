# Changelog: Apparent for Swift

All notable changes to this SDK. Versions follow [Semantic Versioning](https://semver.org); every Apparent SDK
(Expo, Swift, Kotlin, Flutter) carries the same version number and sends the same wire format.

## 0.3.0

- No code changes. Same version as `apparent-expo` 0.3.0, which adds the in-app chat (this SDK gets it later).

## 0.2.2

- No code changes. README: the `disabled` example is a real call (`Apparent.start(app:key:disabled:)`).

## 0.2.1

- Housekeeping release, no code changes: the public source no longer carries a signing team id in the Flutter example.

## 0.2.0

First release on Swift Package Manager (the public mirror's tags start at `0.2.1`).

- Swift Package for iOS 15+ and macOS 12+, no dependencies, with a privacy manifest.
- Same wire format and behaviour as `apparent-expo` 0.2.0 and passes the shared conformance scenario.
- Offline queue, screens (`.apparentScreen`), properties, identify/reset, crashes, opt-out, consent, deep links,
  tapped notifications, `beforeSend`, simulator flag, dropped count, wrong-key warning.
- Batches say `"v": "swift-0.2.0"`.
