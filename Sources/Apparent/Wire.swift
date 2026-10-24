import Foundation

/// A queued event, saved exactly like the Expo SDK saves it. `a`/`u` = whose event it was when it was tracked
/// (the person can log in or out before it is sent).
struct Queued: Equatable {
    var n: String
    var t: Int64
    var s: String
    var i: String
    var p: [String: ApparentValue]?
    var a: String
    var u: String?

    var json: JSON {
        var o: [String: JSON] = ["n": .string(n), "t": .int(t), "s": .string(s), "i": .string(i), "a": .string(a), "u": u.map(JSON.string) ?? .null]
        if let p { o["p"] = .object(p.mapValues(JSON.init)) }
        return .object(o)
    }

    init(n: String, t: Int64, s: String, i: String, p: [String: ApparentValue]? = nil, a: String, u: String?) {
        self.n = n; self.t = t; self.s = s; self.i = i; self.p = p; self.a = a; self.u = u
    }

    /// A saved event, or nil when it is broken: it needs a name, a time, a session and an insert id (SPEC 4).
    init?(json: JSON) {
        guard let n = json["n"]?.text(max: Limits.maxName), let t = json["t"]?.int64,
              let s = json["s"]?.text(max: 64), let i = json["i"]?.text(max: Limits.maxName) else { return nil }
        self.n = n
        self.t = t
        self.s = s
        self.i = i
        a = json["a"]?.text(max: Limits.maxId) ?? ""
        u = json["u"]?.text(max: Limits.maxId)
        if let o = json["p"]?.object {
            self.p = cleanProps(o.sorted { $0.key < $1.key }.compactMap { k, v in v.apparentValue.map { (k, $0) } })
        }
    }
}

/// What is kept on the phone between launches: the same shape as the Expo SDK's `apparent:v2`.
struct Saved: Equatable {
    var anon: String
    var anonSource: String // "provider" | "own" | "reset"
    var userId: String?
    var props: [String: ApparentValue]
    var optedOut: Bool
    /// Set once optIn() was called: with `optOutByDefault`, only then is anything collected. Left out until then
    /// (saved as `"consent": true`, like the Expo SDK).
    var consent: Bool
    /// "1.0.6 (42)" the last time the app ran, to spot updates.
    var app: String?
    var queue: [Queued]

    var json: JSON {
        var o: [String: JSON] = [
            "v": .int(2), "anon": .string(anon), "anonSource": .string(anonSource), "userId": userId.map(JSON.string) ?? .null,
            "props": .object(props.mapValues(JSON.init)), "optedOut": .bool(optedOut), "app": app.map(JSON.string) ?? .null,
            "queue": .array(queue.map(\.json)),
        ]
        if consent { o["consent"] = .bool(true) }
        return .object(o)
    }

    init(anon: String, anonSource: String, userId: String?, props: [String: ApparentValue], optedOut: Bool, consent: Bool = false,
         app: String?, queue: [Queued]) {
        self.anon = anon; self.anonSource = anonSource; self.userId = userId; self.props = props
        self.optedOut = optedOut; self.consent = consent; self.app = app; self.queue = queue
    }

    /// Saved state from this version, an older one, another SDK or a broken disk: read field by field, keeping what is
    /// valid and starting fresh for the rest (SPEC 4). nil only when it isn't an object at all. Every field written
    /// above is read back here; `testEverySavedFieldSurvivesARelaunch` fails when one is forgotten.
    init?(json: JSON) {
        guard json.object != nil else { return nil }
        anon = json["anon"]?.text(max: Limits.maxId) ?? ""
        let source = json["anonSource"]?.string
        anonSource = source == "provider" || source == "reset" ? source! : "own"
        userId = json["userId"]?.text(max: Limits.maxId)
        var props: [(String, ApparentValue)] = []
        for (k, v) in (json["props"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let v = v.apparentValue, v != .null { props.append((k, v)) }
        }
        self.props = cleanProps(props) ?? [:]
        optedOut = json["optedOut"]?.bool == true // "true" as text is not an opt-out
        consent = json["consent"]?.bool == true
        app = json["app"]?.text(max: Limits.maxId)
        queue = (json["queue"]?.array ?? []).compactMap(Queued.init(json:))
    }
}

/// The phone, sent once per batch as `d`.
struct Device: Equatable {
    var platform: String
    var os: String
    var app: String?
    var build: String?
    var model: String?
    var locale: String?
    var region: String?
    var tz: String?
    /// Running in the iOS Simulator. Sent as `"simulator": true` only then; real phones leave the key out.
    var simulator: Bool = false

    var appVersion: String? { app.map { "\($0) (\(build ?? "?"))" } }
}

enum Wire {
    /// The body of `POST /i`, field for field what the Expo SDK sends. The batch's `d.anon` / `d.user` come from its
    /// first event; other events carry `a` / `u` only where they differ.
    static func batch(app: String, key: String, version: String, sentAt: Int64, device: Device, events: [Queued], currentAnon: String = "") -> JSON {
        let first = events.first
        let anon = first.map { $0.a.isEmpty ? currentAnon : $0.a } ?? currentAnon
        let user = first?.u
        var d: [String: JSON] = [
            "platform": .string(device.platform), "os": .string(device.os), "app": opt(device.app), "build": opt(device.build),
            "model": opt(device.model), "locale": opt(device.locale), "region": opt(device.region), "tz": opt(device.tz),
            "anon": .string(anon), "user": opt(user),
        ]
        if device.simulator { d["simulator"] = .bool(true) }
        let e: [JSON] = events.map { q in
            var o: [String: JSON] = ["n": .string(q.n), "t": .int(q.t), "s": .string(q.s), "i": .string(q.i)]
            if let p = q.p { o["p"] = .object(p.mapValues(JSON.init)) }
            if !q.a.isEmpty && q.a != anon { o["a"] = .string(q.a) }
            if q.u != user { o["u"] = opt(q.u) }
            return .object(o)
        }
        return .object(["a": .string(app), "k": .string(key), "v": .string(version), "sa": .int(sentAt), "d": .object(d), "e": .array(e)])
    }

    private static func opt(_ s: String?) -> JSON { s.map(JSON.string) ?? .null }
}

/// 32 random hex characters, like the Expo SDK's ids.
func newId() -> String {
    var g = SystemRandomNumberGenerator()
    let hex = Array("0123456789abcdef")
    return String((0..<32).map { _ in hex[Int(g.next() % 16)] })
}

func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

/// Retry-After as seconds or an HTTP date, kept between 1 s and 1 h.
func retryAfterSeconds(_ header: String?) -> TimeInterval? {
    guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else { return nil }
    var secs: TimeInterval?
    if let n = Double(header) { secs = n }
    else {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = f.date(from: header) { secs = date.timeIntervalSinceNow }
    }
    guard let s = secs, s.isFinite else { return nil }
    return min(3600, max(1, s))
}
