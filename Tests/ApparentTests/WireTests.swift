import Foundation
import XCTest
@testable import Apparent

/// The Swift SDK must save and send exactly what the Expo SDK does. `Fixtures/expo-batch.json` is recorded from the
/// Expo SDK itself (`scripts/make-expo-fixture.ts`): its saved state while a batch was in flight, and that batch.
final class WireTests: SDKTestCase {
    func testReadsTheExpoSavedStateAndWritesItBackTheSame() throws {
        let fx = try fixture("expo-batch")
        let saved = try XCTUnwrap(Saved(json: fx["saved"]!))
        XCTAssertEqual(saved.queue.count, 8)
        XCTAssertEqual(saved.anonSource, "reset")
        XCTAssertEqual(saved.json, fx["saved"]!, "same keys, same values, nulls included")
    }

    func testBuildsTheSameBatchAsExpo() throws {
        let fx = try fixture("expo-batch")
        let saved = try XCTUnwrap(Saved(json: fx["saved"]!))
        let body = fx["body"]!
        let d = body["d"]!
        let device = Device(platform: d["platform"]!.string!, os: d["os"]!.string!, app: d["app"]?.string, build: d["build"]?.string,
                            model: d["model"]?.string, locale: d["locale"]?.string, region: d["region"]?.string, tz: d["tz"]?.string)
        let ours = Wire.batch(app: body["a"]!.string!, key: body["k"]!.string!, version: body["v"]!.string!, sentAt: body["sa"]!.int64!,
                              device: device, events: saved.queue, currentAnon: saved.anon)
        XCTAssertEqual(ours, body)
    }

    func testTheSameCallsMakeTheSameEventsAsExpo() async throws {
        let fx = try fixture("expo-batch")
        let expo = fx["body"]!["e"]!.array!
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        // The same calls as scripts/make-expo-fixture.ts.
        c.setProperties(["language": "de", "plan": "free"])
        c.track("paywall_view", properties: ["source": "onboarding", "price": 4.99, "count": 3, "trial": true, "coupon": nil])
        c.screen("practice/[topic]", properties: ["path": "/practice/recht"])
        c.screen("exam")
        c.identify(userID: "user-1")
        c.track("purchase", properties: ["product": "pro_lifetime"])
        c.logout()
        c.track("after_logout")
        c.captureError(NSError(domain: "x", code: 1), how: "boundary")
        await settle(c)
        let body = try XCTUnwrap(server.requests.first?.body)
        let ours = body["e"]!.array!
        XCTAssertEqual(ours.map { $0["n"]! }, expo.map { $0["n"]! })
        for (a, b) in zip(ours, expo) {
            let name = b["n"]!.string!
            XCTAssertEqual(Set(a.object!.keys), Set(b.object!.keys), "fields of \(name)")
            var pa = a["p"]?.object ?? [:], pb = b["p"]?.object ?? [:]
            if name == "error" { // the message and stack are the platform's own
                for k in ["message", "stack", "type"] { XCTAssertNotNil(pa[k], k); pa[k] = nil; pb[k] = nil }
            }
            XCTAssertEqual(pa, pb, "properties of \(name)")
            if let u = b.object?["u"] { XCTAssertEqual(a["u"], u) }
        }
        let d = body["d"]!
        // In the iOS Simulator `d` also says `"simulator": true` (real phones leave it out, like the fixture).
        XCTAssertEqual(Set(d.object!.keys).subtracting(DeviceInfo.isSimulator ? ["simulator"] : []), Set(fx["body"]!["d"]!.object!.keys))
        XCTAssertEqual(d["simulator"], DeviceInfo.isSimulator ? .bool(true) : nil)
        XCTAssertEqual(d["user"], .null)
        XCTAssertEqual(Set(body.object!.keys), ["a", "k", "v", "sa", "d", "e"])
        XCTAssertEqual(body["v"]?.string, "swift-\(ApparentClient.sdkVersion)")
    }

    func testAnEventOfSomeoneElseCarriesItsOwnIds() {
        let device = Device(platform: "ios", os: "18.0", app: "1.0", build: "1", model: "iPhone15,2", locale: "en-DE", region: "DE", tz: "Europe/Berlin")
        let events = [
            Queued(n: "a", t: 1, s: "s", i: "1", a: "anon1", u: "user-1"),
            Queued(n: "b", t: 2, s: "s", i: "2", a: "anon1", u: nil),
            Queued(n: "c", t: 3, s: "s", i: "3", a: "anon2", u: "user-1"),
        ]
        let body = Wire.batch(app: "x", key: "k", version: "v", sentAt: 5, device: device, events: events)
        XCTAssertEqual(body["d"]?["anon"], .string("anon1"))
        XCTAssertEqual(body["d"]?["user"], .string("user-1"))
        let e = body["e"]!.array!
        XCTAssertNil(e[0].object?["a"]); XCTAssertNil(e[0].object?["u"])
        XCTAssertEqual(e[1].object?["u"], .null, "signed out: an explicit null")
        XCTAssertEqual(e[2]["a"], .string("anon2"))
    }

    func testJSONWriterEscapesAndKeepsNumbers() {
        let j = JSON.object(["s": .string("a\"b\\c\n\u{1}é"), "i": .int(1792765561641), "d": .double(4.99), "w": .double(3), "n": .null, "b": .bool(false)])
        var expected = j.object!
        expected["w"] = .int(3) // JSON has one kind of number: 3.0 reads back as 3
        XCTAssertEqual(JSON.parse(j.data), .object(expected))
        XCTAssertTrue(j.text.contains("1792765561641"))
        XCTAssertTrue(j.text.contains("\"w\":3"))
    }

    func testRetryAfter() {
        XCTAssertEqual(retryAfterSeconds("2"), 2)
        XCTAssertEqual(retryAfterSeconds("0"), 1)
        XCTAssertEqual(retryAfterSeconds("99999"), 3600)
        XCTAssertNil(retryAfterSeconds("soon"))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "GMT"); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let s = try! XCTUnwrap(retryAfterSeconds(f.string(from: Date().addingTimeInterval(30))))
        XCTAssertTrue((28...31).contains(s), "\(s)")
    }

    func testValuesAreCutLikeJavaScript() {
        XCTAssertEqual(String(repeating: "a", count: 600).cut(500).count, 500)
        XCTAssertEqual("😀😀".cut(3), "😀", "never half an emoji")
        let many = (0..<50).map { ("k\($0)", ApparentValue.int($0)) }
        XCTAssertEqual(cleanProps(many)?.count, 40)
        XCTAssertEqual(cleanProps([("x", .double(.nan))])?["x"], .null)
        XCTAssertNil(cleanProps([]))
    }
}
