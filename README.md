# Apparent for Swift

Product events for your [Apparent](https://apparent.fyi) dashboard from iOS 15+ and macOS 12+ apps. A Swift Package with
no dependencies. It sends exactly what the Expo SDK (`sdk/expo`) sends, so a Swift app and an Expo app look the same in Apparent.

## Install

Xcode: File › Add Package Dependencies… › `https://github.com/AhmedAshour/apparent-swift` › Up to Next Major
Version from `0.2.1`, product `Apparent`.

`Package.swift`:

```swift
.package(url: "https://github.com/AhmedAshour/apparent-swift", from: "0.2.1"),
// target dependencies:
.product(name: "Apparent", package: "apparent-swift"),
```

## Quick start

```swift
import Apparent
import SwiftUI

@main struct MyApp: App {
    init() {
        Apparent.start(app: "einb", key: "<write key>")            // Connect page › your app › SDK key
        Apparent.linkRevenueCat { Purchases.shared.attribution.setAttributes($0) } // optional
    }
    var body: some Scene { WindowGroup { HomeView().apparentScreen("home") } }
}

Apparent.track("paywall_view", properties: ["source": "onboarding", "price": 4.99])
Apparent.setProperties(["language": "de", "plan": "free"])     // on every event; nil removes one
Apparent.identify(userID: user.id)                             // signed in; Apparent.logout() when they sign out
```

For development builds: `Apparent.start(app:key:disabled: true)` stores and sends nothing.

## What else it does

- **Automatic events:** `first_open`, `app_open` (each visit, not background launches), `app_updated`, `app_background`
  (seconds in the app), `screen_view`, `error`.
- **Screens:** `.apparentScreen("name")` in SwiftUI, or `Apparent.screen("name")`. Repeats of the current screen are ignored;
  each view says where it came from. UIKit apps can turn on automatic screens with `Apparent.trackUIKitScreens()` (off by default).
- **Sign-in rules:** the install's random id never changes on sign-in, so what someone did before signing in stays theirs.
  `logout()` (or `reset()`, the other SDKs' name) starts a new id, drops the user id and properties. Earlier events keep the old ids.
- **Purchases:** with RevenueCat, `linkRevenueCat` puts `apparent_id` on the customer. Without it, StoreKit 2:
  `Apparent.observeStoreKitTransactions()` at launch (renewals, refunds, Ask to Buy) and
  `Apparent.trackPurchase(try await product.purchase())`. Each transaction is sent once (`purchase`, `subscription_renewed`, `refund`).
- **Crashes:** uncaught exceptions and crash signals (Swift runtime errors, bad memory access, abort) are written to disk as
  the app goes down and sent on the next launch as `error` with `fatal: true, how: "crash"`. Another crash reporter keeps working.
  `Apparent.captureError(error)` for errors you catch.
- **Doesn't lose data:** every event is on disk within a quarter second and right away when the app goes to the background;
  one send at a time; a batch leaves the disk only when the server has it; 10 s per request; retries back off from 2 s to
  5 min and honour `Retry-After`; too-large batches are split; up to 1,000 events wait offline for a week.
  It sends every 10 s, at 20 events, and when the app goes to the background (with a little background time from iOS).
  Batches carry at most 100 events (the server keeps up to 500 and says how many it `dropped`), so a long offline queue
  goes out in several requests and nothing is cut.
- **Right from the start:** `track`, `identify` and `logout` can be called on the line after `start`, without waiting.
  Every call runs on one queue behind the saved state, so the first events get the saved user and properties and a
  logout right at launch stays a logout.
- **Wrong app id or key:** the server answers 401 and the events are dropped (retrying can't fix a key). In Debug builds
  (or with `debug = true`) the SDK prints once: `Apparent: app id or key is wrong — events are not being saved`.
- **Simulators and Macs:** in the iOS Simulator the model is the Mac's processor (`"arm64"`) and the batch says
  `"simulator": true`, so Apparent leaves it out of every count (real phones don't send the key). macOS apps, Mac Catalyst
  and iPhone apps running on a Mac send `platform: "macos"` with the Mac's model (`"Mac14,3"`), shown apart from iPhones.
- **Opt-out:** `Apparent.optOut()` / `optIn()`, remembered across launches and saved at once.
- **Consent first:** `ApparentConfiguration(…, optOutByDefault: true)` collects nothing until `Apparent.optIn()`, on
  later launches too until then. `optIn()` is saved (`"consent": true`), so the next launch starts collecting.
- **Links that open the app:** `.apparentDeepLinks()` on your root view, or `Apparent.handleDeepLink(url)` where you
  handle links yourself (`onOpenURL`, `scene(_:openURLContexts:)`, `application(_:open:options:)`, a universal link's
  `webpageURL`). Sends `deep_link_opened` with `url` (parameters whose name has token, code, password, secret, key,
  auth, session or sig in it become `[redacted]`, a `user:password@` is dropped, cut to 500) and `utm_source`,
  `utm_medium`, `utm_campaign` when the link has them. A campaign link that opens the app on its first day counts as
  where that install came from. Off with `trackDeepLinks: false`.
- **Tapped notifications:** `Apparent.handleNotificationResponse(response)` first in
  `userNotificationCenter(_:didReceive:withCompletionHandler:)` (or `handleNotificationOpened(userInfo:id:)` with the
  payload). Sends `push_opened` once per tap with only `campaign` (else `utm_campaign`) and `title` from your own data
  in the payload, never the text people saw (`aps.alert`). Dismissing isn't a tap. Off with `trackPushOpens: false`.
- **beforeSend:** `ApparentConfiguration(…, beforeSend: { event in … })` sees every event (automatic ones too) before
  it is saved: change its `name` or `properties`, or return `nil` to drop it. A hook that throws keeps the event as it
  was (debug builds say so once). It runs on Apparent's own queue, not the main thread.
- **Holds up when things go wrong** (SPEC 1.6, 2.3, 4, 6): `Retry-After` is waited exactly, never sooner; waits run on
  a clock that doesn't move when the phone's time is changed; `identify`, `logout` and opting out are on disk at once,
  so a kill right after a sign-in or a logout keeps it; broken saved state is read field by field (bad saved events are
  dropped, the rest kept); a disk write that takes longer than a second no longer holds sending; blank event and
  screen names are ignored; dates are sent as ISO time, arrays and dictionaries as JSON text, `NaN` as `null`; a
  `start` without an app id, a key or an http(s) address is ignored (a later good one works), and bad numbers in the
  configuration fall back to the defaults.
- Options (session length, an id you already have, your own intake URL…): `Apparent.start(ApparentConfiguration(…))`.

## Privacy (App Store privacy labels)

The package includes `PrivacyInfo.xcprivacy`: no tracking, no tracking domains, no required-reason APIs.
No IDFA, no IDFV, no App Tracking Transparency prompt. The IP address is used for the country and not kept.

What to answer in App Store Connect › App Privacy, for data Apparent collects:

| Data type | Collected | Linked to the person | Used for tracking | Purpose |
|---|---|---|---|---|
| Product Interaction (events, screens, visits) | Yes | No | No | Analytics |
| Device ID (a random install id made by the SDK) | Yes | No | No | Analytics |
| Crash Data | Yes | No | No | Analytics, App Functionality |
| Other Diagnostic Data (errors you report) | Yes | No | No | Analytics, App Functionality |
| Coarse Location (country, from the IP address on the server) | Yes | No | No | Analytics |
| User ID, only if you call `identify(userID:)` | Yes | **Yes** | No | Analytics |
| Purchase History, only with StoreKit tracking or a purchase event | Yes | No (Yes if you call `identify`) | No | Analytics |

If you call `identify(userID:)`, everything above is linked to the person: answer "Linked to the user" for each.
Also sent with each batch: app version and build, OS version, device model ("iPhone15,2"), language, region setting, time zone.

## Develop

```sh
cd sdk/swift && swift test                    # unit tests, on the Mac
node sdk/swift/scripts/fake-intake.mjs 8787   # a local intake that prints what arrives (run from the repo root)
xcodebuild -project sdk/swift/Example/Example.xcodeproj -scheme Example \
  -destination 'id=<simulator id>' -derivedDataPath ~/ci-ios/apparent-swift build
```

Conformance ([`sdk/conformance`](../conformance/README.md), the same scenario every Apparent SDK passes): start
`node sdk/conformance/intake.ts`, then `sdk/swift/conformance.sh` (another port: `PORT=4301` for both). It installs the
example fresh on the simulator, runs launch 1 and 2 with `-apparentConformance <url> -step 1|2` (launch 2 tracks and logs
out in the app's `init`, right behind `start`) and runs `check.ts` (all 26 rules pass).
Unit tests on the simulator too: `xcodebuild -scheme Apparent -destination 'id=<simulator id>' test` from `sdk/swift`.

The example app otherwise sends to `http://127.0.0.1:8787` (the fake intake), never to the real one. Launch it with
`SIMCTL_CHILD_APPARENT_DEMO=1` (main calls), `crash-swift` or `crash-exception`, then launch again to see the crash arrive.

`Tests/ApparentTests/Fixtures/expo-batch.json` is recorded from the Expo SDK (`node --import ./sdk/expo/test/setup.mjs
sdk/swift/scripts/make-expo-fixture.ts`); the tests check that the Swift SDK reads its saved queue and sends the same batch.
Batches say `"v": "swift-0.2.1"`.
