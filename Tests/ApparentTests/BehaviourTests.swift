import Foundation
import XCTest
@testable import Apparent

final class BehaviourTests: SDKTestCase {
    private func device(_ version: String, _ build: String) -> Device {
        Device(platform: "ios", os: "18.0", app: version, build: build, model: "iPhone15,2", locale: "en-DE", region: "DE", tz: "Europe/Berlin")
    }

    // MARK: Visits

    func testFirstOpenOnceAndAppUpdatedAfterAnUpdate() async {
        let server = FakeServer()
        let storage = MemStorage()
        let a = launch(storage, server, device: device("1.0.0", "1"))
        await settle(a)
        a.shutdown()
        let b = launch(storage, server, device: device("1.0.0", "1"))
        await settle(b)
        b.shutdown()
        let c = launch(storage, server, device: device("1.1.0", "7"))
        await settle(c)
        XCTAssertEqual(server.names.filter { $0 == "first_open" }.count, 1)
        let updated = server.event("app_updated")
        XCTAssertEqual(updated?.p["from_version"], .string("1.0.0 (1)"))
        XCTAssertEqual(updated?.p["to_version"], .string("1.1.0 (7)"))
        XCTAssertEqual(server.names.filter { $0 == "app_open" }.count, 3)
    }

    func testALaunchInTheBackgroundIsNotAVisitUntilOpened() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.initialState = .background }
        await settle(c)
        XCTAssertFalse(server.names.contains("app_open"))
        c.onQueue { c.onAppState(.active) }
        await settle(c)
        XCTAssertEqual(server.event("app_open")?.p["cold"], .bool(true))
    }

    func testTimeInTheAppIsSentAndALongBreakStartsANewVisit() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.sessionTimeout = 0.1 }
        let first = c.onQueue { c.sessionId }
        await sleep(0.05)
        c.onQueue { c.onAppState(.inactive); c.onAppState(.background) }
        c.onQueue { c.onAppState(.active) } // a short break: same visit
        XCTAssertEqual(c.onQueue { c.sessionId }, first)
        c.onQueue { c.onAppState(.background) }
        await sleep(0.15)
        c.onQueue { c.onAppState(.active) } // a long break: a new visit
        await settle(c)
        XCTAssertNotEqual(c.onQueue { c.sessionId }, first)
        XCTAssertEqual(server.names.filter { $0 == "app_background" }.count, 2)
        let opens = server.seen.values.filter { $0.n == "app_open" }.map { $0.p["cold"] }
        XCTAssertEqual(Set(opens.compactMap { $0 }), [.bool(true), .bool(false)])
    }

    func testGoingToTheBackgroundSavesAndSendsRightAway() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server)
        await settle(c)
        c.track("last_tap")
        let sent = expectation(description: "sent")
        c.onQueue { c.onAppState(.background, done: { sent.fulfill() }) }
        await fulfillment(of: [sent], timeout: 2)
        XCTAssertTrue(server.names.contains("last_tap"))
        XCTAssertTrue(server.names.contains("app_background"))
    }

    // MARK: Properties and screens

    func testPropertiesGoOnEveryEventAndNilRemovesThem() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        c.setProperties(["language": "de", "plan": "free"])
        c.track("one")
        c.setProperties(["plan": nil])
        c.track("two", properties: ["count": 2])
        await settle(c)
        XCTAssertEqual(server.event("one")?.p, ["language": .string("de"), "plan": .string("free")])
        XCTAssertEqual(server.event("two")?.p, ["language": .string("de"), "count": .int(2)])
    }

    func testPropertiesAreRemembered() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server)
        c.setProperties(["plan": "pro"])
        c.shutdown()
        let again = launch(storage, server)
        again.track("later")
        await settle(again)
        XCTAssertEqual(server.event("later")?.p["plan"], .string("pro"))
    }

    func testLongValuesAreCutBeforeTheyAreSaved() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server)
        c.track(String(repeating: "n", count: 200), properties: ["text": .string(String(repeating: "x", count: 900))])
        await sleep(0.3)
        let e = storage.savedQueue.last!
        XCTAssertEqual(e.n.count, 80)
        XCTAssertEqual(e.p?["text"], .string(String(repeating: "x", count: 500)))
    }

    func testScreensIgnoreRepeatsAndSayWhereTheyCameFrom() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        c.screen("home")
        c.screen("home")
        c.screen("practice", properties: ["topic": "recht"])
        await settle(c)
        let views = server.seen.values.filter { $0.n == "screen_view" }.sorted { $0.t < $1.t || ($0.t == $1.t && $0.p["screen"] == .string("home")) }
        XCTAssertEqual(views.count, 2)
        XCTAssertEqual(views[0].p, ["screen": .string("home")])
        XCTAssertEqual(views[1].p, ["screen": .string("practice"), "from": .string("home"), "topic": .string("recht")])
    }

    // MARK: People

    func testOptingOutStopsCollectionAndIsRemembered() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server)
        await settle(c)
        c.optOut()
        c.track("after_opt_out")
        await settle(c)
        XCTAssertFalse(server.names.contains("after_opt_out"))
        c.shutdown()
        let again = launch(storage, server)
        XCTAssertTrue(again.isOptedOut)
        again.track("still_out")
        await settle(again)
        XCTAssertFalse(server.names.contains("still_out"))
        again.optIn()
        again.track("back_in")
        await settle(again)
        XCTAssertTrue(server.names.contains("back_in"))
    }

    func testLogoutGivesANewIdAndEarlierEventsKeepTheOldOne() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        c.identify(userID: "user-1")
        c.track("before")
        let oldId = c.anonymousID
        c.logout()
        c.track("after")
        await settle(c)
        XCTAssertEqual(server.event("before")?.anon, oldId)
        XCTAssertEqual(server.event("before")?.user, "user-1")
        XCTAssertNotEqual(server.event("after")?.anon, oldId)
        XCTAssertNil(server.event("after")?.user)
    }

    func testLoginKeepsTheInstallIdAndIsRemembered() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server)
        let id = c.anonymousID
        c.identify(userID: "user-1")
        c.shutdown()
        let again = launch(storage, server)
        XCTAssertEqual(again.anonymousID, id)
        again.track("signed_in")
        await settle(again)
        XCTAssertEqual(server.event("signed_in")?.user, "user-1")
        XCTAssertEqual(server.event("signed_in")?.anon, id)
    }

    func testAnIdFromTheAppIsUsedButNotAfterALogout() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server) { $0.anonymousID = { "inst_abc" } }
        XCTAssertEqual(c.anonymousID, "inst_abc")
        c.logout()
        c.shutdown()
        let again = launch(storage, server) { $0.anonymousID = { "inst_abc" } }
        XCTAssertNotEqual(again.anonymousID, "inst_abc")
    }

    func testTheIdStaysTheSameAfterLoginEvenWhenTheAppsIdChanges() {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server) { $0.anonymousID = { "$device:abc" } }
        c.identify(userID: "user-1")
        c.shutdown()
        let again = launch(storage, server) { $0.anonymousID = { "user-1" } } // Mixpanel's distinct_id after identify()
        XCTAssertEqual(again.anonymousID, "$device:abc")
    }

    func testDevelopmentModeStoresAndSendsNothing() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server) { $0.disabled = true }
        c.track("dev")
        await settle(c)
        XCTAssertEqual(server.requests.count, 0)
        XCTAssertEqual(storage.count, 0)
    }

    func testLinkRevenueCatStoresTheIdOnTheCustomer() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        let got = expectation(description: "attributes")
        let box = Box()
        c.linkRevenueCat { attrs in box.value = attrs; got.fulfill() }
        await fulfillment(of: [got], timeout: 2)
        XCTAssertEqual(box.value, ["apparent_id": c.anonymousID])
    }

    func testAnEventIdIsSentOnceEvenWhenTrackedTwice() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        c.track("purchase", properties: ["product_id": "pro"], eventID: "storekit:purchase:42")
        c.track("purchase", properties: ["product_id": "pro"], eventID: "storekit:purchase:42")
        await settle(c)
        XCTAssertEqual(server.names.filter { $0 == "purchase" }.count, 1, "the server keeps one event per id")
    }

    // MARK: Device

    func testTheRealDeviceIsDescribed() {
        let d = DeviceInfo.read()
        #if os(macOS)
        XCTAssertEqual(d.platform, "macos")
        #else
        XCTAssertEqual(d.platform, "ios")
        #endif
        XCTAssertNotNil(d.model)
        XCTAssertFalse(d.os.isEmpty)
        XCTAssertNotNil(d.tz)
    }
}

final class Box: @unchecked Sendable { var value: [String: String] = [:] }
