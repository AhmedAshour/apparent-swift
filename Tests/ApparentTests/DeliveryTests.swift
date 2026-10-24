import Foundation
import XCTest
@testable import Apparent

/// Does not lose data: the same promises as sdk/expo/test/sdk.test.ts.
final class DeliveryTests: SDKTestCase {
    func testABurstIsDeliveredOnceOneRequestAtATime() async {
        let server = FakeServer()
        server.latency = 0.04
        let c = launch(MemStorage(), server)
        for i in 0..<60 { c.track("burst_\(i)") }
        for i in 0..<10 { await sleep(0.01); c.track("tap_\(i)") }
        await settle(c)
        XCTAssertEqual(server.seen.count, 72, "first_open + app_open + 60 + 10")
        XCTAssertEqual(server.maxInFlight, 1, "never two sends at once")
        XCTAssertEqual(server.requests.reduce(0) { $0 + ($1.body["e"]?.array?.count ?? 0) }, 72, "no event sent twice")
    }

    func testARequestThatNeverAnswersTimesOutAndTheEventsGoLater() async {
        let server = FakeServer()
        server.mode = .hang
        let c = launch(MemStorage(), server) { $0.requestTimeout = 0.06 }
        for i in 0..<5 { c.track("e\(i)") }
        await c.flush()
        XCTAssertEqual(server.seen.count, 0)
        server.mode = .ok
        await sleep(0.08)
        await settle(c)
        XCTAssertEqual(server.seen.count, 7)
    }

    func testEventsAreOnDiskWithinAQuarterSecondAndSurviveAKill() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server)
        await settle(c)
        for i in 0..<12 { c.track("before_kill_\(i)") }
        await sleep(0.3)
        XCTAssertEqual(storage.savedQueue.count, 12, "all 12 saved without any send")
        // Killed: no shutdown, no flush. A new launch reads the same disk.
        let again = launch(storage, server)
        await settle(again)
        XCTAssertEqual(server.names.filter { $0.hasPrefix("before_kill_") }.count, 12)
    }

    func testACrashWhileABatchIsSentKeepsThatBatch() async {
        let server = FakeServer()
        let storage = MemStorage()
        server.mode = .hang
        let c = launch(storage, server) { $0.requestTimeout = 0.15 }
        c.track("important")
        c.flush(completion: nil)
        await sleep(0.03)
        XCTAssertTrue(storage.savedQueue.contains { $0.n == "important" }, "still on disk while in flight")
        server.mode = .ok
        let again = launch(storage, server)
        await settle(again)
        XCTAssertTrue(server.names.contains("important"))
    }

    func testAFailingServerIsRetriedLessAndLessOften() async {
        let server = FakeServer()
        server.mode = .s500
        let c = launch(MemStorage(), server) { $0.retryBase = 0.04 }
        let end = Date().addingTimeInterval(0.7)
        while Date() < end { await c.flush(); await sleep(0.005) }
        let at = server.requests.map(\.at)
        let gaps = zip(at.dropFirst(), at).map { $0.timeIntervalSince($1) }
        XCTAssertLessThanOrEqual(at.count, 6, "only \(at.count) tries in 0.7 s, not one per call")
        for i in 1..<max(1, gaps.count) { XCTAssertGreaterThan(gaps[i], gaps[i - 1] * 1.2, "gaps grow: \(gaps)") }
        server.mode = .ok
        await sleep(0.4)
        await settle(c)
        XCTAssertEqual(server.seen.count, 2, "delivered once the server is back")
    }

    func testRetryAfterIsRespected() async {
        let server = FakeServer()
        server.mode = .s429
        server.retryAfter = "2"
        let c = launch(MemStorage(), server)
        let end = Date().addingTimeInterval(0.5)
        while Date() < end { await c.flush(); await sleep(0.01) }
        XCTAssertEqual(server.requests.count, 1)
    }

    func testBatchesTheServerFindsTooLargeAreSplit() async {
        let server = FakeServer()
        server.maxEvents = 10
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        for i in 0..<45 { c.track("e\(i)") }
        await settle(c)
        XCTAssertEqual(server.seen.count, 47)
    }

    func testABatchTheServerRefusesIsDroppedNotRetriedForever() async {
        let server = FakeServer()
        server.mode = .s400
        let c = launch(MemStorage(), server)
        await settle(c)
        await c.flush()
        XCTAssertEqual(server.requests.count, 1)
    }

    func testEventsOlderThanAWeekAreNotSent() async {
        let server = FakeServer()
        let storage = MemStorage()
        let old = Queued(n: "stale", t: nowMs() - 8 * 24 * 3600_000, s: "s", i: "old1", a: "x", u: nil)
        storage.put(Saved(anon: "x", anonSource: "own", userId: nil, props: [:], optedOut: false, app: "1.0.0 (1)", queue: [old]))
        let c = launch(storage, server)
        await settle(c)
        XCTAssertFalse(server.names.contains("stale"))
        XCTAssertTrue(server.names.contains("app_open"))
    }

    func testTheQueueKeepsTheNewestEventsWhenFull() async {
        let server = FakeServer()
        server.mode = .offline
        let c = launch(MemStorage(), server) { $0.maxQueue = 50; $0.flushAt = 1000 }
        for i in 0..<80 { c.track("e\(i)") }
        let q = c.onQueue { c.queue }
        XCTAssertEqual(q.count, 50)
        XCTAssertEqual(q.last?.n, "e79")
    }

    func testEachBatchCarriesThePhonesClock() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        await settle(c)
        let sa = server.requests[0].body["sa"]!.int64!
        XCTAssertLessThan(abs(sa - nowMs()), 2000)
    }

    func testFlushesOnItsOwnAtTwentyEvents() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        for i in 0..<18 { c.track("e\(i)") }
        await sleep(0.2)
        XCTAssertEqual(server.requests.count, 1, "first_open + app_open + 18 = 20")
        _ = c
    }

    func testTheFileStorageKeepsTheQueueBetweenLaunches() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apparent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let server = FakeServer()
        server.mode = .offline
        let c = launch(FileStorage(directory: dir), server)
        c.track("kept")
        c.shutdown()
        let saved = try XCTUnwrap(JSON.parse(Data(contentsOf: dir.appendingPathComponent("state-v2.json"))))
        XCTAssertEqual(saved["v"], .int(2))
        XCTAssertTrue(saved["queue"]!.array!.contains { $0["n"] == .string("kept") })
        server.mode = .ok
        let again = launch(FileStorage(directory: dir), server)
        await settle(again)
        XCTAssertTrue(server.names.contains("kept"))
        XCTAssertEqual(again.anonymousID, saved["anon"]?.string)
    }
}
