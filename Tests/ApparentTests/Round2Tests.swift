import Foundation
import XCTest
@testable import Apparent

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [String] = []
    func add(_ s: String) { lock.lock(); _all.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return _all }
}

/// Round 2 of the spec: simulators, macOS, wrong keys, big queues, events tracked right after start.
final class Round2Tests: SDKTestCase {
    private func savedState(anon: String = "saved-anon") -> Saved {
        Saved(anon: anon, anonSource: "own", userId: "u1", props: ["plan": .string("free")], optedOut: false, app: nil, queue: [])
    }

    /// A client that is started but not waited for: calls go in right behind `start`, like an app's first lines.
    private func startNoWait(_ storage: ApparentStorage, _ server: FakeServer) -> ApparentClient {
        let c = ApparentClient()
        clients.append(c)
        c.start(config(storage, server))
        return c
    }

    func testAnEventRightAfterStartGetsTheSavedUserAndProperties() async {
        let storage = MemStorage()
        storage.put(savedState())
        let server = FakeServer()
        let c = startNoWait(storage, server)
        c.track("early")
        await settle(c)
        let e = try! XCTUnwrap(server.event("early"))
        XCTAssertEqual(e.user, "u1")
        XCTAssertEqual(e.p["plan"]?.string, "free")
        XCTAssertEqual(e.anon, "saved-anon")
    }

    func testALogoutRightAfterStartIsNotUndone() async {
        let storage = MemStorage()
        storage.put(savedState())
        let server = FakeServer()
        let c = startNoWait(storage, server)
        c.reset()
        c.track("after")
        await settle(c)
        let e = try! XCTUnwrap(server.event("after"))
        XCTAssertNotEqual(e.anon, "saved-anon")
        XCTAssertNil(e.user)
        XCTAssertNil(e.p["plan"])
        c.shutdown()

        // The next launch still has the logged-out person.
        let again = launch(storage, server)
        again.track("next_launch")
        await settle(again)
        let n = try! XCTUnwrap(server.event("next_launch"))
        XCTAssertEqual(n.anon, e.anon)
        XCTAssertNil(n.user)
        XCTAssertNil(n.p["plan"])
    }

    func testAWrongKeyWarnsOnceAndDropsTheEvents() async {
        let server = FakeServer()
        server.mode = .s401
        let lines = Lines()
        let c = ApparentClient()
        clients.append(c)
        c.onQueue { c.warn = { lines.add($0) } }
        c.start(config(MemStorage(), server))
        _ = c.anonymousID
        await settle(c)
        c.track("again")
        await settle(c)
        XCTAssertEqual(server.requests.count, 2, "each batch tried once, then dropped")
        XCTAssertEqual(c.queuedEventCount, 0)
        XCTAssertEqual(lines.all, ["Apparent: app id or key is wrong — events are not being saved"])
    }

    func testABigQueueGoesOutInBatchesOfAHundredAtMost() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 10_000 }
        for i in 0..<250 { c.track("e\(i)") }
        await settle(c)
        XCTAssertEqual(server.seen.count, 252, "first_open + app_open + 250")
        XCTAssertEqual(server.requests.reduce(0) { $0 + ($1.body["e"]?.array?.count ?? 0) }, 252, "none sent twice")
        XCTAssertTrue(server.requests.allSatisfy { ($0.body["e"]?.array?.count ?? 0) <= 100 })
    }

    func testTheSimulatorSaysSoAndRealPhonesLeaveItOut() {
        var device = Device(platform: "ios", os: "18.0", app: "1.0", build: "1", model: "arm64", locale: "en-DE", region: "DE", tz: "Europe/Berlin")
        let events = [Queued(n: "x", t: 1, s: "s", i: "i", a: "a", u: nil)]
        XCTAssertNil(Wire.batch(app: "x", key: "k", version: "v", sentAt: 5, device: device, events: events)["d"]?.object?["simulator"])
        device.simulator = true
        XCTAssertEqual(Wire.batch(app: "x", key: "k", version: "v", sentAt: 5, device: device, events: events)["d"]?["simulator"], .bool(true))
        #if targetEnvironment(simulator)
        XCTAssertTrue(DeviceInfo.read().simulator)
        #else
        XCTAssertFalse(DeviceInfo.read().simulator)
        #endif
    }

    func testAMacIsMacOS() {
        #if os(macOS)
        XCTAssertEqual(DeviceInfo.read().platform, "macos")
        XCTAssertNotNil(DeviceInfo.read().model, "hw.model, e.g. Mac14,3")
        XCTAssertFalse(DeviceInfo.read().simulator)
        #endif
    }
}
