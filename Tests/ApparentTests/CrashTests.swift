import Foundation
import XCTest
@testable import Apparent

final class CrashTests: SDKTestCase {
    /// One crash folder for the whole test process: crash handlers are installed once per app.
    static let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apparent-crash-\(ProcessInfo.processInfo.processIdentifier)")

    private func crashLaunch(_ server: FakeServer) -> ApparentClient {
        launch(FileStorage(directory: Self.dir), server) { $0.captureErrors = true }
    }

    func testAnUncaughtExceptionIsSavedThenSentOnTheNextLaunch() async throws {
        let server = FakeServer()
        server.mode = .offline
        let c = crashLaunch(server)
        c.identify(userID: "user-9")
        c.screen("exam/result")
        let id = c.anonymousID
        c.shutdown() // writes the crash context
        let reporter = try XCTUnwrap(c.crashReporter)
        reporter.exceptionCaughtForTests(NSException(name: .invalidArgumentException, reason: "-[NSNull length]: unrecognized selector"))
        clients.removeAll()
        CrashReporter.resetForTests()

        server.mode = .ok
        let again = crashLaunch(server)
        await settle(again)
        let e = try XCTUnwrap(server.event("error"))
        XCTAssertEqual(e.p["fatal"], .bool(true))
        XCTAssertEqual(e.p["how"], .string("crash"))
        XCTAssertEqual(e.p["type"], .string("NSInvalidArgumentException"))
        XCTAssertEqual(e.p["message"], .string("-[NSNull length]: unrecognized selector"))
        XCTAssertEqual(e.p["screen"], .string("exam/result"))
        XCTAssertEqual(e.anon, id)
        XCTAssertEqual(e.user, "user-9")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent(CrashReporter.exceptionFile).path), "sent once")
    }

    func testACrashSignalRecordBecomesAnErrorEvent() async throws {
        let server = FakeServer()
        let c = crashLaunch(server)
        await settle(c)
        c.shutdown()
        clients.removeAll()
        // What the signal handler writes (it can't run in a test without ending it).
        let record = #"{"sig":5,"t":\#(nowMs()),"ctx":{"s":"sess","a":"anon-x","u":null,"screen":"home"}}"#
        try Data(record.utf8).write(to: Self.dir.appendingPathComponent(CrashReporter.signalFile))
        let again = crashLaunch(server)
        await settle(again)
        let e = try XCTUnwrap(server.event("error"))
        XCTAssertEqual(e.p["type"], .string("SIGTRAP"))
        XCTAssertEqual(e.p["fatal"], .bool(true))
        XCTAssertEqual(e.p["screen"], .string("home"))
        XCTAssertEqual(e.anon, "anon-x")
        XCTAssertNil(e.user)
    }

    func testTheSignalHandlerWritesTheCrashAndItIsSentOnTheNextLaunch() async throws {
        let server = FakeServer()
        server.mode = .offline
        let c = crashLaunch(server)
        await settle(c, timeout: 0.1)
        c.screen("checkout")
        let id = c.anonymousID
        c.shutdown()
        clients.removeAll()
        CrashReporter.raiseForTests(SIGSEGV)
        let written = try String(contentsOf: Self.dir.appendingPathComponent(CrashReporter.signalFile), encoding: .utf8)
        XCTAssertTrue(written.hasPrefix(#"{"sig":11,"t":"#), written)
        server.mode = .ok
        let again = crashLaunch(server)
        await settle(again)
        let e = try XCTUnwrap(server.event("error"))
        XCTAssertEqual(e.p["type"], .string("SIGSEGV"))
        XCTAssertEqual(e.p["how"], .string("crash"))
        XCTAssertEqual(e.p["screen"], .string("checkout"))
        XCTAssertEqual(e.anon, id)
        XCTAssertLessThan(abs(e.t - nowMs()), 5000)
    }

    func testAnErrorLoopIsCappedPerVisit() async {
        let server = FakeServer()
        let c = launch(MemStorage(), server) { $0.flushAt = 1000 }
        for _ in 0..<50 { c.captureError(URLError(.timedOut)) }
        await settle(c)
        let errors = server.seen.values.filter { $0.n == "error" }
        XCTAssertEqual(errors.count, 20)
        XCTAssertEqual(errors.first?.p["type"], .string("NSURLErrorDomain -1001"))
        XCTAssertEqual(errors.first?.p["how"], .string("reported"))
        XCTAssertEqual(errors.first?.p["fatal"], .bool(false))
    }

    func testSwiftErrorsAreNamedByTheirType() {
        enum PaywallError: Error { case noProducts }
        struct Explained: LocalizedError { var errorDescription: String? { "Nothing to buy" } }
        XCTAssertEqual(ApparentClient.describe(PaywallError.noProducts).type, "PaywallError")
        XCTAssertEqual(ApparentClient.describe(PaywallError.noProducts).message, "noProducts")
        XCTAssertEqual(ApparentClient.describe(Explained()).type, "Explained")
        XCTAssertEqual(ApparentClient.describe(Explained()).message, "Nothing to buy")
    }
}
