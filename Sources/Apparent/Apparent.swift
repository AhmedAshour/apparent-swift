import Foundation

/// Apparent for Swift: product events for your Apparent dashboard, the same as the Expo SDK sends.
///
///     Apparent.start(app: "einb", key: "<write key>")
///     Apparent.track("paywall_view", properties: ["source": "onboarding"])
///     Text("Hi").apparentScreen("home")
///
/// Automatic events: `first_open`, `app_open` (each visit, not background launches), `app_updated`,
/// `app_background` (seconds in the app), `screen_view`, `error` (crashes, sent on the next launch), and with one line
/// of wiring each, `deep_link_opened` (`.apparentDeepLinks()`) and `push_opened` (`handleNotificationResponse`).
public enum Apparent {
    /// The one client behind the static calls.
    public static let shared = ApparentClient()

    /// Start once, as early as you can (your `App`'s `init` or `application(_:didFinishLaunchingWithOptions:)`).
    /// - Parameters:
    ///   - app: the app's id in Apparent.
    ///   - key: the app's write key (Connect page). It can only add events.
    ///   - apiURL: where events go. Default https://in.apparent.fyi.
    ///   - disabled: nothing is stored or sent, for development builds.
    public static func start(app: String, key: String, apiURL: URL = URL(string: "https://in.apparent.fyi")!, disabled: Bool = false) {
        shared.start(ApparentConfiguration(app: app, key: key, apiURL: apiURL, disabled: disabled))
    }

    /// Start with every option (session timeout, crash capture, an id you already have…).
    public static func start(_ configuration: ApparentConfiguration) {
        shared.start(configuration)
    }

    /// Record something a person did. Names: lowercase_snake. Properties: flat values.
    public static func track(_ name: String, properties: ApparentProperties? = nil) {
        shared.track(name, properties: properties)
    }

    /// Record that a screen was shown (repeats of the current one are ignored). In SwiftUI use `.apparentScreen("name")`.
    public static func screen(_ name: String, properties: ApparentProperties? = nil) {
        shared.screen(name, properties: properties)
    }

    /// Properties added to every event from now on, e.g. `["language": "de", "plan": "pro"]`. `nil` removes one.
    public static func setProperties(_ properties: ApparentProperties) {
        shared.setProperties(properties)
    }

    /// The signed-in person. The install's id stays the same, so what they did before signing in stays theirs.
    public static func identify(userID: String?) {
        shared.identify(userID: userID)
    }

    /// Someone signed out: a new anonymous id, no user id, no properties. Earlier events keep the old ids.
    public static func logout() {
        shared.logout()
    }

    /// The same as `logout()`.
    public static func reset() { shared.reset() }

    /// Report an error you caught yourself.
    public static func captureError(_ error: Error, properties: ApparentProperties? = nil) {
        shared.captureError(error, properties: properties)
    }

    /// Store this install's Apparent id on the RevenueCat customer (attribute `apparent_id`), so purchases join to
    /// what people did. No RevenueCat dependency: pass the call.
    ///
    ///     Apparent.linkRevenueCat { Purchases.shared.attribution.setAttributes($0) }
    public static func linkRevenueCat(setAttributes: @escaping @Sendable ([String: String]) throws -> Void) {
        shared.linkRevenueCat(setAttributes: setAttributes)
    }

    /// Stop collecting (someone declined analytics). Remembered across launches.
    public static func optOut() { shared.optOut() }
    public static func optIn() { shared.optIn() }
    public static var isOptedOut: Bool { shared.isOptedOut }

    /// This install's random id (never the IDFA or IDFV).
    public static var anonymousID: String { shared.anonymousID }

    /// Events saved on the phone and not delivered yet.
    public static var queuedEventCount: Int { shared.queuedEventCount }

    /// Send what is queued now. It also happens on its own every 10 seconds, at 20 events and when the app goes away.
    public static func flush() async { await shared.flush() }
}
