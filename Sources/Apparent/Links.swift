import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

/// A link that opened the app, safe to store (SPEC 3.1), exactly like the Expo SDK's `cleanDeepLink`: every query or
/// fragment parameter whose name contains token, code, password, passwd, secret, key, auth, session or sig becomes
/// `[redacted]`, a `user:password@` is dropped, and the whole link is cut to 500 characters. The `utm_source`,
/// `utm_medium` and `utm_campaign` values come back on their own (cut to 100), when the link has them.
func cleanDeepLink(_ raw: String) -> (url: String, utm: [String: String]) {
    var url = raw
    if let re = try? NSRegularExpression(pattern: "^([a-z][a-z0-9+.-]*://)[^/?#@]*@", options: [.caseInsensitive]) {
        url = re.stringByReplacingMatches(in: url, range: NSRange(url.startIndex..., in: url), withTemplate: "$1")
    }
    var utm: [String: String] = [:]
    func scrub(_ part: String) -> String {
        part.components(separatedBy: "&").map { pair -> String in
            guard let eq = pair.firstIndex(of: "=") else { return pair }
            let k = String(pair[..<eq])
            let v = String(pair[pair.index(after: eq)...])
            let name = k.removingPercentEncoding ?? k
            if name.range(of: "^utm_(source|medium|campaign)$", options: [.regularExpression, .caseInsensitive]) != nil {
                let value = v.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? v
                if !value.isEmpty { utm[name.lowercased()] = value.cut(100) }
                return pair
            }
            let secret = name.range(of: "token|code|password|passwd|secret|key|auth|session|sig", options: [.regularExpression, .caseInsensitive]) != nil
            return secret ? "\(k)=[redacted]" : pair
        }.joined(separator: "&")
    }
    var fragment: String?
    if let hash = url.firstIndex(of: "#") {
        fragment = String(url[url.index(after: hash)...])
        url = String(url[..<hash])
    }
    if let q = url.firstIndex(of: "?") {
        url = String(url[..<q]) + "?" + scrub(String(url[url.index(after: q)...]))
    }
    if let fragment { url += "#" + (fragment.contains("=") ? scrub(fragment) : fragment) }
    return (url.cut(Limits.maxValue), utm)
}

/// `push_opened`'s properties from a notification's payload: only `campaign` (else `utm_campaign`) and `title` that
/// the app put in its own data, never the shown title or body (`aps.alert`): they can be personal (SPEC 3.1).
func pushProperties(_ userInfo: [AnyHashable: Any]) -> ApparentProperties {
    func pick(_ key: String) -> String? {
        for source in [userInfo, userInfo["data"] as? [AnyHashable: Any] ?? [:]] {
            if let s = source[key] as? String, !s.isEmpty { return s.cut(Limits.maxValue) }
        }
        return nil
    }
    var p: ApparentProperties = [:]
    if let c = pick("campaign") ?? pick("utm_campaign") { p["campaign"] = .string(c) }
    if let t = pick("title") { p["title"] = .string(t) }
    return p
}

extension ApparentClient {
    /// A link opened the app (a URL scheme, a universal link): sends `deep_link_opened` with the link, secrets in it
    /// redacted, and its utm_ fields. Call it from `.onOpenURL`, `scene(_:openURLContexts:)` or
    /// `application(_:open:options:)`; `.apparentDeepLinks()` does it in SwiftUI.
    public func handleDeepLink(_ url: URL) {
        let link = url.absoluteString
        guard !link.isEmpty else { return }
        q.async {
            guard let cfg = self.cfg, cfg.trackDeepLinks else { return }
            let clean = cleanDeepLink(link)
            var p: ApparentProperties = ["url": .string(clean.url)]
            for (k, v) in clean.utm { p[k] = .string(v) }
            self.enqueueAutomatic("deep_link_opened", p)
        }
    }

    /// Someone tapped a notification: sends `push_opened` with only the `campaign` and `title` from its data.
    /// `id` (the notification's identifier) makes repeats of one tap count once.
    public func handleNotificationOpened(userInfo: [AnyHashable: Any], id: String? = nil) {
        let p = pushProperties(userInfo)
        q.async {
            guard let cfg = self.cfg, cfg.trackPushOpens else { return }
            if let id, !id.isEmpty {
                if id == self.lastPushId { return } // the launch and the delegate can both report one tap
                self.lastPushId = id
            }
            self.enqueueAutomatic("push_opened", p)
        }
    }

    #if canImport(UserNotifications) && !os(tvOS)
    /// From `userNotificationCenter(_:didReceive:withCompletionHandler:)`. Dismissing a notification isn't a tap.
    public func handleNotificationResponse(_ response: UNNotificationResponse) {
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
        let request = response.notification.request
        handleNotificationOpened(userInfo: request.content.userInfo, id: request.identifier)
    }
    #endif
}

public extension Apparent {
    /// Send `deep_link_opened` for a link that opened the app (secrets in it redacted). In SwiftUI,
    /// `.apparentDeepLinks()` on your root view does it; otherwise call this where you handle the link.
    static func handleDeepLink(_ url: URL) { shared.handleDeepLink(url) }

    /// Send `push_opened` for a tapped notification, with only the `campaign` and `title` you put in its data
    /// (never what it said). Pass the payload's `userInfo` and, if you have it, the notification's identifier.
    static func handleNotificationOpened(userInfo: [AnyHashable: Any], id: String? = nil) {
        shared.handleNotificationOpened(userInfo: userInfo, id: id)
    }

    #if canImport(UserNotifications) && !os(tvOS)
    /// Call it first in `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
    static func handleNotificationResponse(_ response: UNNotificationResponse) { shared.handleNotificationResponse(response) }
    #endif
}

#if canImport(SwiftUI)
import SwiftUI

public extension View {
    /// Sends `deep_link_opened` for every link that opens the app (`onOpenURL`). Put it on your root view. Your own
    /// `.onOpenURL` keeps working; with your own handler you can also call `Apparent.handleDeepLink(url)` in it instead.
    func apparentDeepLinks() -> some View {
        onOpenURL { Apparent.handleDeepLink($0) }
    }
}
#endif
