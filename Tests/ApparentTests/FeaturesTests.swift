import Foundation
import XCTest
@testable import Apparent

/// Links, tapped notifications, beforeSend and consent first, as sdk/expo/test/features.test.ts; plus the clock and
/// configuration cases of hardening.test.ts that need the SDK's test hooks.
final class FeaturesTests: SDKTestCase {
    // MARK: deep_link_opened

    func testALinkThatOpensTheAppIsSentWithItsCampaignAndWithoutSecrets() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        c.handleDeepLink(URL(string: "myapp://user:pw@open/offer?utm_source=newsletter&utm_campaign=spring%20sale&access_token=abc&id=7#code=xyz")!)
        await settle(c)
        let e = try! XCTUnwrap(server.event("deep_link_opened"))
        XCTAssertEqual(e.p["url"]?.string, "myapp://open/offer?utm_source=newsletter&utm_campaign=spring%20sale&access_token=[redacted]&id=7#code=[redacted]")
        XCTAssertEqual(e.p["utm_source"]?.string, "newsletter")
        XCTAssertEqual(e.p["utm_campaign"]?.string, "spring sale")
        XCTAssertNil(e.p["utm_medium"])
    }

    func testTrackDeepLinksFalseSendsNoDeepLinkAndANormalLaunchSendsNone() async {
        let server = FakeServer()
        let off = launch(MemStorage(), server) { $0.trackDeepLinks = false }
        off.handleDeepLink(URL(string: "myapp://x")!)
        await settle(off)
        let on = launch(MemStorage(), server)
        await settle(on)
        XCTAssertNil(server.event("deep_link_opened"))
    }

    func testCleanDeepLinkLikeExpo() {
        XCTAssertEqual(cleanDeepLink("https://x.test/a").url, "https://x.test/a")
        XCTAssertEqual(cleanDeepLink("https://x.test/a#section").url, "https://x.test/a#section")
        XCTAssertEqual(cleanDeepLink("https://x.test/?" + String(repeating: "a", count: 600)).url.count, 500)
        XCTAssertEqual(cleanDeepLink("app://p?Session_ID=1&mySig=2&ok=3&flag").url, "app://p?Session_ID=[redacted]&mySig=[redacted]&ok=3&flag")
        XCTAssertEqual(cleanDeepLink("app://p?utm_medium=e+mail").utm, ["utm_medium": "e mail"])
    }

    // MARK: push_opened

    func testPushOpenedOncePerTapWithOnlyCampaignAndTitleFromTheData() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server)
        let payload: [AnyHashable: Any] = ["aps": ["alert": ["title": "Hi Ahmed", "body": "Your secret code is 1234"]],
                                           "utm_campaign": "winback", "title": "winback_v2", "body": "personal"]
        c.handleNotificationOpened(userInfo: payload, id: "n1")
        c.handleNotificationOpened(userInfo: payload, id: "n1") // the same tap, reported twice
        c.handleNotificationOpened(userInfo: ["campaign": "daily", "utm_campaign": "ignored"], id: "n2")
        c.handleNotificationOpened(userInfo: ["aps": ["alert": "only text"]])
        await settle(c)
        let pushes = server.seen.values.filter { $0.n == "push_opened" }.sorted { $0.t < $1.t }
        XCTAssertEqual(pushes.count, 3)
        let first = try! XCTUnwrap(pushes.first { $0.p["campaign"]?.string == "winback" })
        XCTAssertEqual(first.p["title"]?.string, "winback_v2")
        XCTAssertNil(first.p["body"])
        XCTAssertTrue(pushes.contains { $0.p["campaign"]?.string == "daily" })
        XCTAssertTrue(pushes.contains { $0.p.isEmpty })
        for p in pushes { XCTAssertTrue(Set(p.p.keys).isSubset(of: ["campaign", "title"])) }
    }

    func testTrackPushOpensFalseIgnoresTaps() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.trackPushOpens = false }
        c.handleNotificationOpened(userInfo: ["campaign": "x"], id: "n1")
        await settle(c)
        XCTAssertNil(server.event("push_opened"))
    }

    // MARK: beforeSend

    struct Boom: Error {}

    func testBeforeSendCanChangeAnEventDropItAndAHookThatThrowsKeepsIt() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) {
            $0.beforeSend = { e in
                var e = e
                switch e.name {
                case "secret": return nil
                case "boom": throw Boom()
                case "rename": e.name = "renamed"; e.properties["email"] = nil; e.properties["long"] = .string(String(repeating: "x", count: 900))
                case "blank": e.name = "  "
                default: break
                }
                return e
            }
        }
        c.track("rename", properties: ["email": "a@b.c", "plan": "pro"])
        c.track("secret")
        c.track("boom", properties: ["k": 1])
        c.track("blank")
        await settle(c)
        XCTAssertNil(server.event("secret"))
        XCTAssertNil(server.event("blank"), "a hook that empties the name drops the event")
        let renamed = try! XCTUnwrap(server.event("renamed"))
        XCTAssertNil(renamed.p["email"])
        XCTAssertEqual(renamed.p["plan"]?.string, "pro")
        XCTAssertEqual(renamed.p["long"]?.string?.count, 500, "cleaned again")
        XCTAssertEqual(server.event("boom")?.p["k"]?.int64, 1)
        XCTAssertNotNil(server.event("app_open"), "automatic events go through it too")
    }

    func testBeforeSendSeesAutomaticEvents() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.beforeSend = { $0.name == "app_open" ? nil : $0 } }
        c.handleDeepLink(URL(string: "app://x")!)
        await settle(c)
        XCTAssertNil(server.event("app_open"))
        XCTAssertNotNil(server.event("first_open"))
        XCTAssertNotNil(server.event("deep_link_opened"))
    }

    // MARK: optOutByDefault

    func testOptOutByDefaultCollectsNothingUntilOptInThenRemembers() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = launch(storage, server) { $0.optOutByDefault = true }
        XCTAssertTrue(c.isOptedOut)
        c.track("before_consent")
        await settle(c)
        XCTAssertEqual(server.seen.count, 0, "nothing at all before consent")
        c.shutdown()

        let again = launch(storage, server) { $0.optOutByDefault = true }
        XCTAssertTrue(again.isOptedOut, "still no consent on the next launch")
        again.optIn()
        again.track("after_consent")
        await settle(again)
        XCTAssertNotNil(server.event("after_consent"))
        XCTAssertEqual(storage.saved?["consent"]?.bool, true)
        again.shutdown()

        let third = launch(storage, server) { $0.optOutByDefault = true }
        XCTAssertFalse(third.isOptedOut, "consent is remembered")
        third.optOut()
        third.shutdown()
        let fourth = launch(storage, server) { $0.optOutByDefault = true }
        XCTAssertTrue(fourth.isOptedOut, "and so is opting out again")
        XCTAssertNil(storage.saved?["consent"])
    }

    func testOptInBeforeTheSavedStateIsReadWins() async {
        let server = FakeServer()
        let storage = MemStorage()
        let c = ApparentClient()
        clients.append(c)
        c.optIn() // before start
        c.start(config(storage, server) { $0.optOutByDefault = true })
        XCTAssertFalse(c.isOptedOut)
        c.track("counted")
        await settle(c)
        XCTAssertNotNil(server.event("counted"))
    }

    func testWithoutOptOutByDefaultTheSavedStateIsWhatItWas() {
        let storage = MemStorage()
        let c = launch(storage, FakeServer())
        c.optIn()
        c.optOut()
        c.optIn()
        c.onQueue {}
        // optIn saves consent, which only matters with optOutByDefault; nothing else changes shape.
        XCTAssertEqual(Set(storage.saved?.object?.keys.map { $0 } ?? []),
                       ["v", "anon", "anonSource", "userId", "props", "optedOut", "app", "queue", "consent"])
        let fresh = MemStorage()
        let d = launch(fresh, FakeServer())
        d.onQueue {}
        XCTAssertNil(fresh.saved?["consent"], "no consent key until optIn()")
    }

    func testEverySavedFieldSurvivesARelaunch() throws {
        let q = Queued(n: "e", t: nowMs(), s: "s1", i: "i1", p: ["k": .string("v")], a: "a1", u: "u1")
        let full = Saved(anon: "a1", anonSource: "provider", userId: "u1", props: ["plan": .string("pro")], optedOut: true,
                         consent: true, app: "1.0 (1)", queue: [q])
        // Every key the SDK writes is read back: a new field the reader forgets fails here.
        let back = try XCTUnwrap(Saved(json: full.json))
        XCTAssertEqual(back, full)
        XCTAssertEqual(back.json, full.json)
        XCTAssertEqual(Set(full.json.object!.keys), ["v", "anon", "anonSource", "userId", "props", "optedOut", "consent", "app", "queue"])
    }

    // MARK: Clocks that jump (SPEC 1.6)

    func testThePhonesClockJumpingBackADayDuringARetryWaitDoesNotStrandTheQueue() async {
        let server = FakeServer()
        server.mode = .s500
        let c = launch(MemStorage(), server) { $0.retryBase = 0.05 }
        c.track("waiting")
        await c.flush()
        c.wallClock = { Date().addingTimeInterval(-86400) } // the person sets the time back a day
        server.mode = .ok
        await sleep(0.1)
        await settle(c)
        XCTAssertNotNil(server.event("waiting"))
    }

    func testAClockThatGoesBackNeverStretchesAWait() async {
        let server = FakeServer()
        server.mode = .s429
        server.retryAfter = "3600"
        let c = launch(MemStorage(), server)
        await c.flush()
        XCTAssertEqual(server.requests.count, 1)
        // The wait's own clock reads a day earlier now: the time left (a day and an hour) is more than was set.
        let start = monotonicNow()
        c.clock = { monotonicNow() - start - 86400 }
        server.mode = .ok
        await settle(c)
        XCTAssertEqual(server.requests.count, 2, "the wait is over instead of a day longer")
    }

    func testTheClockJumpingForwardADayJustRetriesSoonerAndDropsNothing() async {
        let server = FakeServer()
        server.mode = .s429
        server.retryAfter = "3600"
        let c = launch(MemStorage(), server)
        c.track("kept")
        await c.flush()
        c.clock = { monotonicNow() + 86400 }
        c.wallClock = { Date().addingTimeInterval(86400) }
        server.mode = .ok
        await settle(c)
        XCTAssertNotNil(server.event("kept"))
    }

    // MARK: Bad configuration (SPEC 6)

    func testNumbersThatWouldBreakTimersAreReplaced() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) {
            $0.flushInterval = .nan; $0.requestTimeout = -1; $0.retryBase = .infinity
            $0.sessionTimeout = .nan; $0.flushAt = 0; $0.maxQueue = -5
        }
        c.track("still_works")
        await settle(c)
        XCTAssertNotNil(server.event("still_works"))
    }

    func testABadAddressIsIgnoredUntilAGoodStart() async {
        let server = FakeServer()
        let c = ApparentClient()
        clients.append(c)
        c.start(config(MemStorage(), server) { $0.apiURL = URL(string: "file:///etc")! })
        XCTAssertNil(c.onQueue { c.cfg })
        c.start(config(MemStorage(), server))
        XCTAssertNotNil(c.onQueue { c.cfg })
    }
}
