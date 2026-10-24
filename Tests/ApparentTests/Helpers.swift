import Foundation
import XCTest
@testable import Apparent

/// A fake Apparent intake that records every request and misbehaves on demand.
final class FakeServer: ApparentTransport, @unchecked Sendable {
    enum Mode { case ok, hang, s500, s429, offline, s400, s401 }
    struct Request { let body: JSON; let at: Date }
    struct Seen { let n: String; let t: Int64; let i: String; let p: [String: JSON]; let anon: String; let user: String? }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _seen: [String: Seen] = [:]
    private var inFlight = 0
    private var _maxInFlight = 0
    var mode: Mode = .ok
    var latency: TimeInterval = 0.005
    var retryAfter = "1"
    var maxEvents = Int.max

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return _requests }
    var seen: [String: Seen] { lock.lock(); defer { lock.unlock() }; return _seen }
    var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }
    /// Event names in the order they happened.
    var names: [String] { seen.values.sorted { ($0.t, $0.n) < ($1.t, $1.n) }.map(\.n) }
    func event(_ name: String) -> Seen? { seen.values.first { $0.n == name } }

    func post(_ url: URL, body: Data, timeout: TimeInterval, completion: @escaping @Sendable (TransportResult) -> Void) {
        let json = JSON.parse(body)!
        lock.lock()
        _requests.append(Request(body: json, at: Date()))
        inFlight += 1
        _maxInFlight = max(_maxInFlight, inFlight)
        let mode = self.mode, latency = self.latency, retryAfter = self.retryAfter, maxEvents = self.maxEvents
        lock.unlock()
        let finish: @Sendable (TransportResult) -> Void = { r in
            self.lock.lock(); self.inFlight -= 1; self.lock.unlock()
            completion(r)
        }
        if mode == .hang {
            // Like URLSession: no answer, then the request's time limit.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(.failed) }
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + latency) {
            switch mode {
            case .offline: return finish(.failed)
            case .s500: return finish(.status(500, retryAfter: nil))
            case .s429: return finish(.status(429, retryAfter: retryAfter))
            case .s400: return finish(.status(400, retryAfter: nil))
            case .s401: return finish(.status(401, retryAfter: nil))
            default: break
            }
            let events = json["e"]?.array ?? []
            if events.count > maxEvents { return finish(.status(413, retryAfter: nil)) }
            let d = json["d"]!
            self.lock.lock()
            for e in events {
                let user: String? = e.object?["u"] != nil ? e["u"]?.string : d["user"]?.string
                self._seen[e["i"]!.string!] = Seen(n: e["n"]!.string!, t: e["t"]!.int64!, i: e["i"]!.string!, p: e["p"]?.object ?? [:],
                                                   anon: e["a"]?.string ?? d["anon"]!.string!, user: user)
            }
            self.lock.unlock()
            finish(.status(200, retryAfter: nil))
        }
    }
}

final class MemStorage: ApparentStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]
    func read(_ name: String) -> Data? { lock.lock(); defer { lock.unlock() }; return files[name] }
    func write(_ name: String, _ data: Data) { lock.lock(); files[name] = data; lock.unlock() }
    func remove(_ name: String) { lock.lock(); files[name] = nil; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return files.count }
    var saved: JSON? { read(ApparentClient.stateFile).flatMap(JSON.parse) }
    var savedQueue: [Queued] { saved.flatMap(Saved.init(json:))?.queue ?? [] }
    func put(_ saved: Saved) { write(ApparentClient.stateFile, saved.json.data) }
}

class SDKTestCase: XCTestCase {
    var clients: [ApparentClient] = []

    override func tearDown() {
        for c in clients { c.shutdown() }
        clients = []
        super.tearDown()
    }

    func config(_ storage: ApparentStorage, _ server: FakeServer, _ edit: (inout ApparentConfiguration) -> Void = { _ in }) -> ApparentConfiguration {
        var c = ApparentConfiguration(app: "test", key: "k", apiURL: URL(string: "https://apparent.test")!, captureErrors: false,
                                      flushInterval: 3600, requestTimeout: 0.2, retryBase: 0.03, storage: storage, transport: server)
        c.observeLifecycle = false
        c.initialState = .active
        edit(&c)
        return c
    }

    /// A new app launch reading `storage`.
    @discardableResult
    func launch(_ storage: ApparentStorage, _ server: FakeServer, device: Device? = nil, _ edit: (inout ApparentConfiguration) -> Void = { _ in }) -> ApparentClient {
        let c = ApparentClient()
        clients.append(c)
        if let device { c.onQueue { c.device = device } }
        c.start(config(storage, server, edit))
        _ = c.anonymousID // waits for the saved state
        return c
    }

    /// Keep sending until nothing is left (or give up).
    func settle(_ c: ApparentClient, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            await c.flush()
            if c.onQueue({ c.queue.count + c.inflight.count }) == 0 { return }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    func sleep(_ seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    }

    func fixture(_ name: String) throws -> JSON {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try XCTUnwrap(JSON.parse(Data(contentsOf: url)))
    }
}
