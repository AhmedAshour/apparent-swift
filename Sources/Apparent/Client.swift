import Foundation
import os

/// How Apparent is set up. Only `app` and `key` are needed.
public struct ApparentConfiguration: Sendable {
    /// The app's id in Apparent (for example "einb").
    public var app: String
    /// The app's write key, from Apparent's Connect page. It can only add events.
    public var key: String
    /// Where events go. Default https://in.apparent.fyi.
    public var apiURL: URL
    /// Nothing is stored or sent. Use it in development: `disabled: isDebugBuild`.
    public var disabled: Bool
    /// The signed-in person, if you already know them at launch.
    public var userID: String?
    /// A stable id you already have (an install id, RevenueCat's app user id) so events and purchases join.
    /// Asked for once, on the first launch only.
    public var anonymousID: (@Sendable () -> String?)?
    /// Prints what is tracked and sent.
    public var debug: Bool
    /// Time in the background before a visit ends. Default 30 minutes.
    public var sessionTimeout: TimeInterval
    /// Report crashes (uncaught exceptions and crash signals, sent on the next launch). Default true.
    public var captureErrors: Bool
    /// Advanced, mostly for tests.
    public var flushInterval: TimeInterval
    public var flushAt: Int
    public var maxQueue: Int
    public var requestTimeout: TimeInterval
    public var retryBase: TimeInterval
    public var storage: ApparentStorage?
    public var transport: ApparentTransport?
    /// Runs on every event (automatic ones too) before it is saved, after its properties are cleaned. Return the event,
    /// changed, or nil to drop it: remove personal data, skip noisy events. If it throws, the event is kept as it was.
    /// It runs on Apparent's own queue, not the main thread.
    public var beforeSend: (@Sendable (ApparentEvent) throws -> ApparentEvent?)?
    /// Collect nothing until `optIn()` is called (apps that ask for consent first). Remembered across launches.
    public var optOutByDefault: Bool
    /// Send `deep_link_opened` from `Apparent.handleDeepLink(_:)` / `.apparentDeepLinks()`. Default true.
    public var trackDeepLinks: Bool
    /// Send `push_opened` from `Apparent.handleNotificationResponse(_:)`. Default true.
    public var trackPushOpens: Bool
    /// Follow the app going to the background and coming back. Off in unit tests.
    var observeLifecycle = true
    /// The app's state at start; read from UIApplication when nil.
    var initialState: AppState?

    public init(
        app: String, key: String, apiURL: URL = URL(string: "https://in.apparent.fyi")!, disabled: Bool = false,
        userID: String? = nil, anonymousID: (@Sendable () -> String?)? = nil, debug: Bool = false,
        sessionTimeout: TimeInterval = 30 * 60, captureErrors: Bool = true, flushInterval: TimeInterval = 10,
        flushAt: Int = 20, maxQueue: Int = 1000, requestTimeout: TimeInterval = 10, retryBase: TimeInterval = 2,
        storage: ApparentStorage? = nil, transport: ApparentTransport? = nil,
        beforeSend: (@Sendable (ApparentEvent) throws -> ApparentEvent?)? = nil, optOutByDefault: Bool = false,
        trackDeepLinks: Bool = true, trackPushOpens: Bool = true
    ) {
        self.app = app; self.key = key; self.apiURL = apiURL; self.disabled = disabled; self.userID = userID
        self.anonymousID = anonymousID; self.debug = debug; self.sessionTimeout = sessionTimeout
        self.captureErrors = captureErrors; self.flushInterval = flushInterval; self.flushAt = flushAt
        self.maxQueue = maxQueue; self.requestTimeout = requestTimeout; self.retryBase = retryBase
        self.storage = storage; self.transport = transport
        self.beforeSend = beforeSend; self.optOutByDefault = optOutByDefault
        self.trackDeepLinks = trackDeepLinks; self.trackPushOpens = trackPushOpens
    }

    /// Why this configuration can't start, or nil when it can. A broken `start` is ignored, so a later good one works.
    var problem: String? {
        let app = app.trimmingCharacters(in: .whitespacesAndNewlines), key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if app.isEmpty || app.utf16.count > Limits.maxId { return "Apparent: start needs your app id" }
        if key.isEmpty || key.utf16.count > 512 { return "Apparent: start needs your write key" }
        if !["http", "https"].contains(apiURL.scheme?.lowercased() ?? "") { return "Apparent: apiURL must be an http(s) address" }
        return nil
    }

    /// Numbers that would break timers or the queue (NaN, 0, negative) replaced by the defaults.
    var sane: ApparentConfiguration {
        var c = self
        func ok(_ v: TimeInterval, _ min: TimeInterval) -> Bool { v.isFinite && v >= min }
        if !ok(c.flushInterval, 0.05) { c.flushInterval = 10 }
        if !ok(c.requestTimeout, 0.01) { c.requestTimeout = 10 }
        if !ok(c.retryBase, 0.001) { c.retryBase = 2 }
        if !ok(c.sessionTimeout, 0) { c.sessionTimeout = 30 * 60 }
        c.flushInterval = min(c.flushInterval, 24 * 3600)
        c.requestTimeout = min(c.requestTimeout, 300)
        c.retryBase = min(c.retryBase, 300)
        if c.flushAt < 1 { c.flushAt = 20 }
        if c.maxQueue < 1 { c.maxQueue = 1000 }
        return c
    }
}

/// An event as `beforeSend` sees it. Change the name or the properties, or return nil to drop it.
public struct ApparentEvent: Sendable, Equatable {
    public var name: String
    public var properties: ApparentProperties
    /// When it was tracked (the phone's clock).
    public let time: Date

    public init(name: String, properties: ApparentProperties = [:], time: Date = Date()) {
        self.name = name; self.properties = properties; self.time = time
    }
}

/// Seconds on a clock that never jumps when the phone's time is changed, and keeps counting while the phone sleeps.
func monotonicNow() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1e9 }

/// The engine behind `Apparent`. Every method is safe from any thread; all state lives on one serial queue,
/// so events keep the order they were tracked in.
///
/// Built not to lose data, like the Expo SDK:
/// - every event is saved within a quarter second, and right away when the app goes to the background or crashes;
/// - one batch is sent at a time, and a batch only leaves the saved queue once the server has it;
/// - each request has a time limit, and retries wait longer each time (and honour Retry-After);
/// - the batch carries the phone's clock, so the server can correct phones set to the wrong time; it ignores duplicates.
public final class ApparentClient: @unchecked Sendable {
    public static let sdkVersion = "0.2.2"
    /// What goes in the batch's `v`: which SDK and version sent it (the Expo SDK sends its plain version).
    static let wireVersion = "swift-\(sdkVersion)"
    static let stateFile = "state-v2.json"

    let q = DispatchQueue(label: "fyi.apparent.sdk")
    private let log = Logger(subsystem: "fyi.apparent", category: "sdk")

    // Everything below is only touched on `q`.
    private(set) var cfg: ApparentConfiguration?
    private var storage: ApparentStorage?
    private var transport: ApparentTransport = URLSessionTransport()
    private var anon = ""
    private var anonSource = "own"
    private var userId: String?
    private var props: [String: ApparentValue] = [:]
    private var optedOut = false
    /// optIn() was called (saved as `consent`): with optOutByDefault, only then is anything collected.
    private var consented = false
    /// optIn() or optOut() before the saved state was read: that choice wins over the saved one.
    private var consentBeforeLoad: Bool?
    private var warnedHook = false
    /// The last tapped notification, so one tap is one push_opened.
    var lastPushId: String?
    private var appVersion: String?
    var queue: [Queued] = []
    var inflight: [Queued] = []
    private(set) var sessionId = newId()
    var device = DeviceInfo.read()
    private(set) var loaded = false
    private var sending = false
    private var sendAgain = false
    private var waiters: [() -> Void] = []
    private var failures = 0
    /// When the next try may go, on `clock` (never the wall clock: a phone whose time changes doesn't strand the queue).
    private var retryAt: TimeInterval = -.infinity
    /// How long the current wait was meant to be, to spot a clock that went back since.
    private var retryWait: TimeInterval = 0
    private var retryReason: String?
    private var batchSize = Limits.maxBatch
    private var persistScheduled = false
    private var timer: DispatchSourceTimer?
    private var lifecycle: Lifecycle?
    private var appState: AppState = .active
    private var activeSince: TimeInterval?
    private var backgroundAt: TimeInterval?
    private var pendingOpen = false
    private(set) var screenName: String?
    private var errorsThisVisit = 0
    var crashReporter: CrashReporter?
    /// The wrong-key warning was printed (once per client).
    private var warnedWrongKey = false
    /// Where warnings go. Tests swap it.
    var warn: (String) -> Void = { message in
        Logger(subsystem: "fyi.apparent", category: "sdk").warning("\(message, privacy: .public)")
        print(message)
    }
    /// Monotonic seconds for waits and visit lengths; the wall clock for event times. Tests move them.
    var clock: () -> TimeInterval = monotonicNow
    var wallClock: () -> Date = { Date() }
    private func now() -> Int64 { Int64((wallClock().timeIntervalSince1970 * 1000).rounded(.down)) }
    /// A disk write that takes longer than this no longer holds sending or `ready()` (SPEC 4). It still finishes.
    static var writeWait: TimeInterval = 1
    private let writer = DispatchQueue(label: "fyi.apparent.sdk.write")
    private let writeLock = NSLock()
    private var writeBusy = false
    private var writeNext: Data?
    static let wrongKeyWarning = "Apparent: app id or key is wrong — events are not being saved"
    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static let queueKey = DispatchSpecificKey<Bool>()

    public init() {
        q.setSpecific(key: Self.queueKey, value: true)
    }

    // MARK: Start

    public func start(_ config: ApparentConfiguration) {
        let state = config.initialState ?? (config.observeLifecycle && Thread.isMainThread ? Lifecycle.current() : .active)
        q.async { self.begin(config, state: state) }
    }

    private func begin(_ input: ApparentConfiguration, state: AppState) {
        guard cfg == nil else { return }
        if let problem = input.problem {
            // Not this one: a later start with an app id and a key still works.
            if Self.isDebugBuild || input.debug { warn(problem) }
            return
        }
        let config = input.sane
        cfg = config
        storage = config.storage ?? FileStorage()
        if let t = config.transport { transport = t }
        if let u = config.userID, !u.isEmpty { userId = u.cut(Limits.maxId) }
        // A launch by a silent push or background fetch is not a visit: wait until the app is really in front.
        appState = state
        if config.disabled {
            anon = newId()
            loaded = true
            debugLog("disabled: nothing is stored or sent")
            return
        }
        if config.captureErrors, let dir = (storage as? FileStorage)?.directory {
            crashReporter = CrashReporter.install(directory: dir)
            crashReporter?.saveBeforeCrash = { [weak self] in self?.saveNowFromAnyThread(timeout: 0.3) }
        }
        restore(config)
        if config.observeLifecycle {
            let l = Lifecycle()
            l.observe { [weak self] s, done in
                guard let self else { done?(); return }
                self.q.async { self.onAppState(s, done: done) }
            }
            lifecycle = l
        }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + config.flushInterval, repeating: config.flushInterval)
        t.setEventHandler { [weak self] in self?.flushOnQueue(nil) }
        t.resume()
        timer = t
    }

    private func restore(_ config: ApparentConfiguration) {
        let saved = storage?.read(Self.stateFile).flatMap(JSON.parse).flatMap(Saved.init(json:))
        let fresh = (saved?.anon ?? "").isEmpty
        var id = saved?.anon ?? ""
        var source = saved?.anonSource ?? "own"
        // Only on first launch: an id that changes after login (Mixpanel's distinct_id) would split one person in two.
        // The server matches signed-in people by user id instead.
        if fresh, let provided = config.anonymousID?(), !provided.isEmpty {
            id = provided.cut(Limits.maxId)
            source = "provider"
        }
        if id.isEmpty { id = newId(); source = "own" }
        anon = id
        anonSource = source
        if userId == nil { userId = saved?.userId }
        props = saved?.props ?? [:]
        if let choice = consentBeforeLoad {
            optedOut = !choice
            consented = choice
        } else {
            consented = saved?.consent ?? false
            // Consent first: nothing is collected until they agreed (optIn), on this launch and later ones.
            optedOut = (saved?.optedOut ?? false) || (config.optOutByDefault && !consented)
        }
        let cutoff = now() - Limits.maxEventAgeMs
        queue = (saved?.queue ?? []).filter { $0.t >= cutoff }
        // A crash from the last run, saved as the app went down.
        if let crash = crashReporter?.takeReport(props: props), !optedOut,
           let kept = hook(crash.n, crash.p, t: crash.t) {
            var e = crash
            e.n = kept.n
            e.p = kept.p
            queue.append(e)
        }
        loaded = true

        let current = device.appVersion
        if fresh { enqueue("first_open") }
        else if let before = saved?.app, let current, before != current {
            enqueue("app_updated", ["from_version": .string(before), "to_version": .string(current)])
        }
        appVersion = current
        if appState == .active { open(cold: true) } else { pendingOpen = true }
        if optedOut { queue = [] }
        persistNow()
    }

    private func open(cold: Bool) {
        pendingOpen = false
        activeSince = clock()
        backgroundAt = nil
        errorsThisVisit = 0
        enqueue("app_open", ["cold": .bool(cold)])
    }

    func onAppState(_ next: AppState, done: (() -> Void)? = nil) {
        let prev = appState
        appState = next
        guard let cfg, loaded, !cfg.disabled else { done?(); return }
        switch next {
        case .active:
            if pendingOpen { open(cold: true) }
            else if let away = backgroundAt {
                if clock() - away > cfg.sessionTimeout {
                    sessionId = newId()
                    open(cold: false)
                } else {
                    activeSince = clock()
                    backgroundAt = nil
                }
            }
            if retryReason == "network" { retryAt = -.infinity } // the network may be back
            flushOnQueue(nil)
        case .background:
            if prev != .background, let since = activeSince {
                let seconds = clock() - since
                enqueue("app_background", ["seconds": .int(seconds.isFinite ? max(0, Int(min(seconds, 1e9).rounded())) : 0)])
                activeSince = nil
                backgroundAt = clock()
            }
            persistNow()
            flushOnQueue(done)
            return
        case .inactive:
            break
        }
    }

    // MARK: Events

    private func enqueue(_ name: String, _ extra: [String: ApparentValue]? = nil, id: String? = nil) {
        guard let cfg else { return }
        if cfg.disabled {
            debugLog("\(name) \(extra.map { JSON.object($0.mapValues(JSON.init)).text } ?? "")")
            return
        }
        if optedOut { return }
        var merged: [(String, ApparentValue)] = props.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        if let extra { merged += extra.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
        let t = now()
        guard let kept = hook(name.cut(Limits.maxName), cleanProps(merged), t: t) else { return }
        let eventId = id.flatMap { $0.isEmpty ? nil : $0.cut(Limits.maxName) } ?? newId()
        let e = Queued(n: kept.n, t: t, s: sessionId, i: eventId, p: kept.p, a: anon, u: userId)
        queue.append(e)
        let over = queue.count + inflight.count - cfg.maxQueue
        if over > 0 { queue.removeFirst(min(over, queue.count)) }
        debugLog("\(e.n) \(e.p.map { JSON.object($0.mapValues(JSON.init)).text } ?? "")")
        schedulePersist()
        if queue.count >= cfg.flushAt { flushOnQueue(nil) }
    }

    /// For the SDK's own events from other files (links, notifications).
    func enqueueAutomatic(_ name: String, _ extra: [String: ApparentValue]) { enqueue(name, extra) }

    /// The app's beforeSend: the event it returns (cleaned again), or nil when it drops it. A hook that throws keeps it.
    private func hook(_ n: String, _ p: [String: ApparentValue]?, t: Int64) -> (n: String, p: [String: ApparentValue]?)? {
        guard let fn = cfg?.beforeSend else { return (n, p) }
        let out: ApparentEvent?
        do {
            out = try fn(ApparentEvent(name: n, properties: p ?? [:], time: Date(timeIntervalSince1970: TimeInterval(t) / 1000)))
        } catch {
            if !warnedHook { warnedHook = true; warn("Apparent: beforeSend threw (\(error)); the event is sent as it was") }
            return (n, p)
        }
        guard let out, Self.isName(out.name) else { return nil }
        return (out.name.cut(Limits.maxName), cleanProps(out.properties.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
    }

    /// Event and screen names: anything but empty or only spaces (SPEC 3.3).
    static func isName(_ name: String) -> Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Record something a person did. Names: lowercase_snake. Properties: flat values.
    public func track(_ name: String, properties: ApparentProperties? = nil) {
        guard Self.isName(name) else { return }
        q.async { self.enqueue(name, properties) }
    }

    /// `eventID` makes the event idempotent: the server keeps the first event with an id and drops repeats.
    func track(_ name: String, properties: ApparentProperties?, eventID: String) {
        guard Self.isName(name) else { return }
        q.async { self.enqueue(name, properties, id: eventID) }
    }

    /// Record that a screen was shown. Repeats of the current screen are ignored.
    public func screen(_ name: String, properties: ApparentProperties? = nil) {
        guard Self.isName(name) else { return }
        q.async {
            guard self.cfg != nil, name != self.screenName else { return }
            let from = self.screenName
            self.screenName = name
            var p = properties ?? [:]
            p["screen"] = .string(name)
            if let from { p["from"] = .string(from) } else { p["from"] = nil }
            self.enqueue("screen_view", p)
            self.updateCrashContext()
        }
    }

    /// Report an error you caught yourself (a failed request, a decoding error).
    public func captureError(_ error: Error, fatal: Bool = false, how: String = "reported", properties: ApparentProperties? = nil) {
        let (type, message) = Self.describe(error)
        // The app's frames, not Apparent's own.
        let stack = Thread.callStackSymbols.dropFirst().filter { !$0.contains("$s8Apparent") }.prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        report(message: message, type: type, fatal: fatal, how: how, stack: stack, properties: properties)
    }

    /// A Swift error's type ("DecodingError") and message; Foundation's errors by domain and code ("NSURLErrorDomain -1001").
    static func describe(_ error: Error) -> (type: String, message: String) {
        let name = String(describing: Swift.type(of: error))
        if name == "NSError" || name.hasPrefix("__") {
            let ns = error as NSError
            return ("\(ns.domain) \(ns.code)", ns.localizedDescription)
        }
        if let localized = (error as? LocalizedError)?.errorDescription { return (name, localized) }
        return (name, String(describing: error))
    }

    func report(message: String, type: String, fatal: Bool, how: String, stack: String?, properties: ApparentProperties?) {
        q.async {
            guard self.cfg != nil, self.errorsThisVisit < Limits.maxErrorsPerVisit else { return }
            self.errorsThisVisit += 1
            var p = properties ?? [:]
            p["message"] = .string(message.cut(300))
            p["type"] = .string(type.isEmpty ? "Error" : type)
            p["fatal"] = .bool(fatal)
            p["how"] = .string(how)
            if let stack, !stack.isEmpty { p["stack"] = .string(stack.cut(1500)) }
            if let s = self.screenName { p["screen"] = .string(s) }
            self.enqueue("error", p)
        }
    }

    /// Who is using the app, once they sign in. `nil` when they sign out (or call `logout()`).
    /// The install's id stays the same, so what they did before signing in stays theirs.
    public func identify(userID: String?) {
        q.async {
            self.userId = userID.flatMap { $0.isEmpty ? nil : $0.cut(Limits.maxId) }
            // Saved now, not in a quarter second: an app killed right after a sign-in or logout must wake up as that person.
            self.persistNow()
            self.updateCrashContext()
        }
    }

    /// Properties added to every event from now on, e.g. `["language": "de", "plan": "pro"]`. `nil` removes one.
    public func setProperties(_ properties: ApparentProperties) {
        q.async {
            for (k, v) in properties {
                let key = k.cut(Limits.maxKey)
                let value = cleanValue(v)
                if value == .null { self.props[key] = nil } else { self.props[key] = value }
            }
            self.schedulePersist()
        }
    }

    public func unsetProperty(_ key: String) {
        q.async {
            self.props[key.cut(Limits.maxKey)] = nil
            self.schedulePersist()
        }
    }

    /// Someone signed out: forget who they were, their properties, and start a new anonymous id and visit.
    /// Events tracked before keep the old id.
    public func logout() {
        q.async {
            self.anon = newId()
            self.anonSource = "reset"
            self.userId = nil
            self.props = [:]
            self.sessionId = newId()
            self.screenName = nil
            self.persistNow()
            self.updateCrashContext()
        }
    }

    /// Stop collecting (someone declined analytics). Remembered across launches; what was queued is thrown away.
    public func optOut() {
        q.async {
            self.optedOut = true
            self.consented = false
            if !self.loaded { self.consentBeforeLoad = false }
            self.queue = []
            self.persistNow()
        }
    }

    /// Start collecting again, or for the first time with `optOutByDefault`. Remembered across launches.
    public func optIn() {
        q.async {
            self.optedOut = false
            self.consented = true
            if !self.loaded { self.consentBeforeLoad = true }
            self.persistNow()
        }
    }

    /// The same as `logout()` (the name the other Apparent SDKs use).
    public func reset() { logout() }

    public var isOptedOut: Bool { q.sync { optedOut } }

    /// Events saved on the phone and not yet delivered (including a batch on its way).
    public var queuedEventCount: Int { q.sync { queue.count + inflight.count } }

    /// Returns once the saved state is read (the install id is final from then on).
    public func ready() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in q.async { c.resume() } }
    }

    /// This install's id. Final once `start` has read the saved state (this waits for it).
    public var anonymousID: String { q.sync { anon } }

    /// Store this person's Apparent id on their RevenueCat customer, so purchases join to what they did:
    ///
    ///     Apparent.linkRevenueCat { Purchases.shared.attribution.setAttributes($0) }
    ///
    /// Call it again after `logout()` (the new id needs linking too).
    public func linkRevenueCat(setAttributes: @escaping @Sendable ([String: String]) throws -> Void) {
        q.async {
            guard self.cfg != nil else { return }
            let attributes = ["apparent_id": self.anon]
            DispatchQueue.main.async {
                do { try setAttributes(attributes) } catch { self.debugLog("could not link RevenueCat: \(error)") }
            }
        }
    }

    // MARK: Sending

    /// Send what is queued now. Safe any time: only one send runs at once.
    public func flush(completion: (@Sendable () -> Void)? = nil) {
        q.async { self.flushOnQueue(completion.map { c in { c() } }) }
    }

    public func flush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in flush { c.resume() } }
    }

    func flushOnQueue(_ done: (() -> Void)?) {
        guard cfg != nil else { done?(); return }
        if let done { waiters.append(done) }
        if sending { sendAgain = true; return }
        sending = true
        drainStep(sent: false)
    }

    private func drainStep(sent: Bool) {
        guard let cfg else { return finishDrain(sent: sent) }
        if cfg.disabled || optedOut {
            queue = []
            return finishDrain(sent: sent)
        }
        let cutoff = now() - Limits.maxEventAgeMs
        if queue.contains(where: { $0.t < cutoff }) { queue.removeAll { $0.t < cutoff } }
        guard !queue.isEmpty, due() else { return finishDrain(sent: sent) }
        let batch = Array(queue.prefix(batchSize))
        queue.removeFirst(batch.count)
        inflight = batch
        // Nothing may be in flight without being on disk: a crash mid-send must not lose it.
        if persistScheduled { persistNow() }
        let body = Wire.batch(app: cfg.app, key: cfg.key, version: Self.wireVersion, sentAt: now(), device: device, events: batch, currentAnon: anon).data
        let url = cfg.apiURL.appendingPathComponent("i")
        transport.post(url, body: body, timeout: cfg.requestTimeout) { result in
            self.q.async { self.handle(result, batch: batch) }
        }
    }

    private func handle(_ result: TransportResult, batch: [Queued]) {
        inflight = []
        guard let cfg else { return finishDrain(sent: true) }
        switch result {
        case .status(let code, _) where (200..<300).contains(code):
            failures = 0; retryAt = -.infinity; retryWait = 0; retryReason = nil
            if batchSize < Limits.maxBatch { batchSize = min(Limits.maxBatch, batchSize * 2) }
            return drainStep(sent: true)
        case .status(413, _):
            if batch.count == 1 { debugLog("dropped one event the server says is too large"); return drainStep(sent: true) }
            batchSize = max(1, batch.count / 2)
            queue.insert(contentsOf: batch, at: 0)
            return drainStep(sent: true)
        case .status(let code, let retryAfter) where code == 408 || code == 429 || code >= 500:
            fail(batch, reason: "server", status: "\(code)", retryAfter: retryAfterSeconds(retryAfter), cfg: cfg)
        case .status(let code, _):
            debugLog("server refused \(batch.count) events (\(code))")
            if code == 401, !warnedWrongKey, Self.isDebugBuild || cfg.debug {
                warnedWrongKey = true
                warn(Self.wrongKeyWarning)
            }
            failures = 0; retryAt = -.infinity; retryWait = 0; retryReason = nil
            return drainStep(sent: true)
        case .failed:
            fail(batch, reason: "network", status: "network", retryAfter: nil, cfg: cfg)
        }
        finishDrain(sent: true)
    }

    private func fail(_ batch: [Queued], reason: String, status: String, retryAfter: TimeInterval?, cfg: ApparentConfiguration) {
        queue.insert(contentsOf: batch, at: 0)
        failures += 1
        retryReason = reason
        // The server's Retry-After exactly (already 1 s .. 1 h), never sooner; our own backoff with ±20 % jitter.
        retryWait = retryAfter ?? min(5 * 60, cfg.retryBase * pow(2, Double(min(failures, 30) - 1))) * Double.random(in: 0.8...1.2)
        retryAt = clock() + retryWait
        debugLog("send failed (\(status)), next try in \(Int(retryWait.rounded())) s")
    }

    /// True once the retry wait is over. A wait that is now longer than it was set to means the clock went back: it's
    /// over too, so a clock change never holds the queue (SPEC 1.6).
    private func due() -> Bool {
        let t = clock()
        if retryAt - t > retryWait { retryAt = t }
        return t >= retryAt
    }

    private func finishDrain(sent: Bool) {
        if sent { persistNow() }
        sending = false
        let done = waiters
        waiters = []
        if sendAgain {
            sendAgain = false
            if !queue.isEmpty && due() {
                // Callers that came in while we were sending wait for this next round too.
                waiters = done
                flushOnQueue(nil)
                return
            }
        }
        for d in done { d() }
    }

    // MARK: Saving

    private func schedulePersist() {
        guard !persistScheduled, loaded else { return }
        persistScheduled = true
        q.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.persistScheduled else { return }
            self.persistNow()
        }
    }

    func persistNow() {
        persistScheduled = false
        guard let cfg, !cfg.disabled, loaded, let storage else { return }
        let all = inflight + queue
        let state = Saved(anon: anon, anonSource: anonSource, userId: userId, props: props, optedOut: optedOut,
                          consent: consented, app: appVersion, queue: Array(all.suffix(cfg.maxQueue)))
        write(state.json.data, to: storage)
        updateCrashContext()
    }

    /// Writes on a queue of its own and waits for it, at most `writeWait`: a disk that never answers must not hold
    /// sending or `ready()` (SPEC 4). While a slow write is still going, later states don't wait: the newest one is
    /// written after it.
    private func write(_ data: Data, to storage: ApparentStorage) {
        writeLock.lock()
        if writeBusy { writeNext = data; writeLock.unlock(); return }
        writeBusy = true
        writeLock.unlock()
        let done = DispatchSemaphore(value: 0)
        writer.async {
            var next: Data? = data
            var first = true
            while let d = next {
                storage.write(Self.stateFile, d)
                self.writeLock.lock()
                next = self.writeNext
                self.writeNext = nil
                if next == nil { self.writeBusy = false }
                self.writeLock.unlock()
                if first { done.signal(); first = false }
            }
        }
        if done.wait(timeout: .now() + Self.writeWait) == .timedOut { debugLog("saving is slow; sending goes on") }
    }

    /// Saves the queue from outside the SDK's queue, waiting at most `timeout` (never forever: the app is going down).
    func saveNowFromAnyThread(timeout: TimeInterval) {
        guard DispatchQueue.getSpecific(key: Self.queueKey) == nil else { return }
        let done = DispatchSemaphore(value: 0)
        q.async { self.persistNow(); done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func updateCrashContext() {
        crashReporter?.setContext(session: sessionId, anon: anon, user: userId, screen: screenName)
    }

    /// Stop timers and listeners after saving what is queued. For tests.
    func shutdown() {
        q.sync {
            timer?.cancel()
            timer = nil
            lifecycle?.stop()
            lifecycle = nil
            persistNow()
        }
    }

    /// Runs `body` on the SDK's queue and waits. For tests.
    func onQueue<T>(_ body: () -> T) -> T { q.sync(execute: body) }

    private func debugLog(_ message: String) {
        guard cfg?.debug == true else { return }
        log.debug("[apparent] \(message, privacy: .public)")
        print("[apparent] \(message)")
    }
}
