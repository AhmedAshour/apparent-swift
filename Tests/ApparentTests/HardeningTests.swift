import Foundation
import XCTest
@testable import Apparent

/// A disk whose writes take `delay` seconds each (a full or broken disk).
final class SlowStorage: ApparentStorage, @unchecked Sendable {
    let inner = MemStorage()
    let delay: TimeInterval
    init(delay: TimeInterval) { self.delay = delay }
    func read(_ name: String) -> Data? { inner.read(name) }
    func write(_ name: String, _ data: Data) { Thread.sleep(forTimeInterval: delay); inner.write(name, data) }
    func remove(_ name: String) { inner.remove(name) }
}

/// The edge cases the big SDKs test in their own suites, as sdk/expo/test/hardening.test.ts (SPEC 1.6, 2.3, 3.3, 4, 6).
final class HardeningTests: SDKTestCase {
    // MARK: Identity while a batch is out

    func testALogoutWhileABatchIsInFlightLosesNothingAndSendsNothingTwice() async {
        let server = FakeServer()
        server.latency = 0.15
        let c = launch(MemStorage(), server)
        await settle(c)
        c.track("before_logout")
        c.flush(completion: nil)
        await sleep(0.03)
        c.reset()
        c.track("after_logout")
        await settle(c)
        let before = try! XCTUnwrap(server.event("before_logout"))
        let after = try! XCTUnwrap(server.event("after_logout"))
        XCTAssertNotEqual(before.anon, after.anon)
        let sent = server.requests.flatMap { $0.body["e"]?.array ?? [] }.compactMap { $0["n"]?.string }
        XCTAssertEqual(sent.filter { $0 == "before_logout" }.count, 1)
        XCTAssertEqual(sent.filter { $0 == "after_logout" }.count, 1)
    }

    // MARK: Saved right away (SPEC 2.3)

    func testASignInIsOnDiskRightAway() {
        let storage = MemStorage()
        let c = launch(storage, FakeServer())
        c.identify(userID: "u1")
        c.onQueue {}
        XCTAssertEqual(storage.saved?["userId"]?.string, "u1", "a kill right after sign-in keeps the user")
    }

    func testIdentifyNilAsALogoutIsOnDiskRightAway() {
        let storage = MemStorage()
        let c = launch(storage, FakeServer())
        c.identify(userID: "u1")
        c.onQueue {}
        c.identify(userID: nil)
        c.onQueue {}
        XCTAssertEqual(storage.saved?["userId"], .null)
    }

    func testALogoutIsOnDiskRightAway() {
        let storage = MemStorage()
        let c = launch(storage, FakeServer())
        c.identify(userID: "u1")
        c.setProperties(["plan": "pro"])
        let anon = c.anonymousID
        c.reset()
        c.onQueue {}
        XCTAssertEqual(storage.saved?["userId"], .null)
        XCTAssertNotEqual(storage.saved?["anon"]?.string, anon)
        XCTAssertEqual(storage.saved?["props"]?.object?.count, 0)
    }

    func testOptingOutAndBackInIsOnDiskRightAway() {
        let storage = MemStorage()
        let c = launch(storage, FakeServer())
        c.optOut()
        c.onQueue {}
        XCTAssertEqual(storage.saved?["optedOut"]?.bool, true)
        c.optIn()
        c.onQueue {}
        XCTAssertEqual(storage.saved?["optedOut"]?.bool, false)
    }

    // MARK: Broken saved state (SPEC 4)

    func testBrokenSavedStateStartsCleanlyAndKeepsWorking() async {
        let cases: [(String, String)] = [
            ("not JSON", "{{{ not json"),
            ("an array", "[1,2,3]"),
            ("a number", "42"),
            ("null", "null"),
            ("a queue that is not a list", #"{"v":2,"anon":"a1","queue":{"n":"x"}}"#),
            ("wrong-typed fields", #"{"v":2,"anon":5,"userId":7,"props":[1],"optedOut":"true","app":false,"queue":[1,"x",null]}"#),
        ]
        for (what, text) in cases {
            let storage = MemStorage()
            storage.write(ApparentClient.stateFile, Data(text.utf8))
            let server = FakeServer()
            let c = launch(storage, server)
            XCTAssertFalse(c.isOptedOut, what)
            XCTAssertFalse(c.anonymousID.isEmpty, what)
            c.track("still_works")
            await settle(c)
            XCTAssertNotNil(server.event("still_works"), what)
            c.shutdown()
            XCTAssertNotNil(storage.saved.flatMap(Saved.init(json:)), "\(what): saved again, and readable")
        }
    }

    func testSavedStateWithoutAVersionKeepsTheInstallIdAndTheUser() {
        let storage = MemStorage()
        storage.write(ApparentClient.stateFile, Data(#"{"anon":"keep-me","userId":"u9","optedOut":false}"#.utf8))
        let c = launch(storage, FakeServer())
        XCTAssertEqual(c.anonymousID, "keep-me")
        XCTAssertEqual(storage.saved?["userId"]?.string, "u9")
    }

    func testBadSavedEventsAreDroppedAndGoodOnesKept() async {
        let storage = MemStorage()
        let t = nowMs() - 1000
        let text = """
        {"v":2,"anon":"a1","anonSource":"own","userId":null,"props":{},"optedOut":false,"app":null,"queue":[
          {"n":"good","t":\(t),"s":"s1","i":"i-good","a":"a1","u":null},
          {"n":"","t":\(t),"s":"s1","i":"i-empty"},
          {"n":"no_session","t":\(t),"i":"i-nos"},
          {"n":"no_insert_id","t":\(t),"s":"s1"},
          {"n":"text_time","t":"yesterday","s":"s1","i":"i-tt"},
          {"n":"bad_props","t":\(t),"s":"s1","i":"i-bp","p":"oops"}
        ]}
        """
        storage.write(ApparentClient.stateFile, Data(text.utf8))
        let server = FakeServer()
        let c = launch(storage, server)
        await settle(c)
        let names = Set(server.names)
        XCTAssertTrue(names.contains("good"))
        XCTAssertTrue(names.contains("bad_props"), "an event with broken properties is kept without them")
        for bad in ["", "no_session", "no_insert_id", "text_time"] { XCTAssertFalse(names.contains(bad), bad) }
    }

    func testAWrongTypedOptedOutIsNotAnOptOut() {
        let storage = MemStorage()
        storage.write(ApparentClient.stateFile, Data(#"{"v":2,"anon":"a1","optedOut":"true","queue":[]}"#.utf8))
        XCTAssertFalse(launch(storage, FakeServer()).isOptedOut)
    }

    // MARK: Storage that fails (SPEC 4)

    func testAStorageWriteThatTakesForeverDoesNotHoldSending() async {
        let storage = SlowStorage(delay: 3)
        let server = FakeServer()
        let started = Date()
        let c = launch(storage, server)
        await c.ready()
        for i in 0..<5 { c.track("slow_disk_\(i)") }
        await settle(c, timeout: 4)
        XCTAssertEqual(server.names.filter { $0.hasPrefix("slow_disk_") }.count, 5)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "a slow disk must not hold sending")
    }

    // MARK: Retry-After (SPEC 1.6)

    func testRetryAfterIsWaitedExactlyNeverSooner() async {
        // Four phones at once: with ±20 % jitter on Retry-After, at least one comes back early almost every time.
        let servers = (0..<4).map { _ -> FakeServer in let s = FakeServer(); s.mode = .s429; s.retryAfter = "1"; return s }
        let cs = servers.map { launch(MemStorage(), $0) }
        await withTaskGroup(of: Void.self) { g in
            for (c, s) in zip(cs, servers) {
                g.addTask {
                    let end = Date().addingTimeInterval(1.6)
                    while Date() < end && s.requests.count < 2 { await c.flush(); try? await Task.sleep(nanoseconds: 5_000_000) }
                }
            }
        }
        for s in servers {
            let at = s.requests.map(\.at)
            XCTAssertEqual(at.count, 2, "tried again once the wait was over")
            if at.count == 2 {
                let gap = at[1].timeIntervalSince(at[0])
                XCTAssertGreaterThanOrEqual(gap, 0.98, "never sooner than Retry-After")
                XCTAssertLessThan(gap, 1.3, "and not much later")
            }
        }
    }

    // MARK: Names and values (SPEC 3.3)

    func testBlankNamesAreIgnoredLongOnesCutAndOthersKept() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        await settle(c)
        let before = server.seen.count
        c.track("")
        c.track("   ")
        c.track("\n\t")
        c.screen("  ")
        c.track(String(repeating: "x", count: 100))
        c.track("Paywall View 🎉")
        await settle(c)
        XCTAssertEqual(server.seen.count - before, 2)
        XCTAssertTrue(server.names.contains(String(repeating: "x", count: 80)))
        XCTAssertTrue(server.names.contains("Paywall View 🎉"))
    }

    func testABrokenFirstStartDoesNotBlockAGoodOne() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = ApparentClient()
        clients.append(c)
        c.start(config(storage, server) { $0.app = "" })
        c.start(config(storage, server) { $0.key = "   " })
        c.track("ignored")
        c.start(config(storage, server))
        c.track("counted")
        await settle(c)
        XCTAssertTrue(server.names.contains("counted"))
        XCTAssertFalse(server.names.contains("ignored"))
        XCTAssertEqual(server.requests.first?.body["a"]?.string, "test")
    }

    func testOddValuesComeOutFlat() {
        let date = Date(timeIntervalSince1970: 1_792_836_000) // 2026-10-24T10:00:00Z
        XCTAssertEqual(ApparentValue(date), .string("2026-10-24T10:00:00.000Z"))
        XCTAssertEqual(ApparentValue([1, "a"] as [Any]), .string(#"[1,"a"]"#))
        XCTAssertEqual(ApparentValue(["k": 1] as [String: Any]), .string(#"{"k":1}"#))
        XCTAssertEqual(ApparentValue(URL(string: "https://x.test/a")!), .string("https://x.test/a"))
        XCTAssertEqual(ApparentValue(NSNull()), .null)
        XCTAssertEqual(ApparentValue(UInt64.max), .string("18446744073709551615"))
        XCTAssertEqual(cleanValue(ApparentValue(Double.nan)), .null)
        XCTAssertEqual(cleanValue(ApparentValue(Float.infinity)), .null)
        XCTAssertEqual(ApparentValue(Optional<Int>.none as Any), .null)
    }

    func testOddValuesNeverStopAnEvent() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        var many: ApparentProperties = [:]
        for i in 0..<60 { many["k\(i)"] = .int(i) }
        many["nan"] = .double(.nan)
        many["inf"] = .double(-.infinity)
        many[String(repeating: "k", count: 200)] = .string(String(repeating: "v", count: 5000))
        c.track("odd", properties: many)
        c.setProperties(["": "empty key", "date": ApparentValue(Date())])
        c.track("after")
        await settle(c)
        let odd = try! XCTUnwrap(server.event("odd"))
        XCTAssertLessThanOrEqual(odd.p.count, 40)
        XCTAssertNotNil(server.event("after"))
    }
}
