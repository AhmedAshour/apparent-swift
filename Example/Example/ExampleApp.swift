import Apparent
import SwiftUI

@main
struct ExampleApp: App {
    init() {
        if let url = Conformance.url {
            // The SDK conformance run (sdk/conformance): default settings, the intake's own app id and key.
            Apparent.start(app: "conformance", key: "conformance-key", apiURL: url)
            // Launch 2 starts right behind start(), before the saved state is read: the user, properties and the
            // logout must still come out right.
            if Conformance.step == 2 { Conformance.earlyStep2() }
            return
        }
        // Never the real intake from here: a local one (sdk/swift/scripts/fake-intake.mjs) unless you pass another.
        let env = ProcessInfo.processInfo.environment
        let url = URL(string: env["APPARENT_API_URL"] ?? "http://127.0.0.1:8787")!
        var config = ApparentConfiguration(app: env["APPARENT_APP"] ?? "example", key: env["APPARENT_KEY"] ?? "example-key", apiURL: url)
        config.debug = true
        Apparent.start(config)
        Apparent.setProperties(["example": true])
    }

    var body: some Scene {
        WindowGroup {
            if Conformance.url != nil {
                // No screens of its own here, so only the scenario's screens are sent.
                Text("Conformance step \(Conformance.step)")
                    .task { await Conformance.run(step: Conformance.step) }
            } else {
                ContentView()
                    .task {
                        // For checks from the command line: `APPARENT_DEMO=1` goes through the main calls once,
                        // `crash-swift` / `crash-exception` crash the app (the crash is sent on the next launch).
                        switch ProcessInfo.processInfo.environment["APPARENT_DEMO"] {
                        case "1": await Demo.run()
                        case "crash-swift": Demo.crashSwift()
                        case "crash-exception": Demo.crashException()
                        default: break
                        }
                    }
            }
        }
    }
}

/// The scenario from sdk/conformance/README.md. Launch arguments: `-apparentConformance <intake url> -step 1|2`.
enum Conformance {
    static var url: URL? { UserDefaults.standard.string(forKey: "apparentConformance").flatMap(URL.init(string:)) }
    static var step: Int { UserDefaults.standard.integer(forKey: "step") }

    struct TestError: LocalizedError { var errorDescription: String? { "conformance test error" } }

    /// The first calls of launch 2, made in the app's init right after `Apparent.start` (no waiting).
    static func earlyStep2() {
        Apparent.track("second_launch")
        Apparent.reset()
        Apparent.track("logged_out")
    }

    static func run(step: Int) async {
        if step == 1 {
            Apparent.screen("home")
            Apparent.screen("home")
            Apparent.screen("settings")
            Apparent.track("conformance_step", properties: ["step": 1, "ok": true, "ratio": 1.5, "text": "héllo wörld", "nothing": nil])
            Apparent.setProperties(["plan": "free"])
            Apparent.identify(userID: "conformance-user")
            Apparent.track("logged_in")
            for n in 0..<25 { Apparent.track("burst", properties: ["n": .int(n)]) }
            Apparent.captureError(TestError())
            Apparent.track("launch1_done")
            await Apparent.flush()
            // Stay open: the SDK keeps retrying until the runner kills the app.
        } else if step == 2 {
            Apparent.track("launch2_done")
            await Apparent.flush()
            while Apparent.queuedEventCount > 0 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                await Apparent.flush()
            }
            Apparent.optOut()
            Apparent.track("opted_out_event")
            await Apparent.flush()
        }
    }
}

enum Demo {
    static func run() async {
        Apparent.screen("demo")
        Apparent.track("paywall_view", properties: ["source": "demo", "price": 4.99, "count": 3, "trial": true, "coupon": nil])
        Apparent.identify(userID: "demo-user")
        Apparent.track("purchase", properties: ["product": "pro_lifetime"])
        Apparent.captureError(URLError(.timedOut))
        Apparent.logout()
        Apparent.track("after_logout")
        await Apparent.flush()
        print("[apparent-demo] done \(Apparent.anonymousID)")
    }

    static func crashSwift() {
        Apparent.screen("about_to_crash")
        let empty: [Int] = []
        _ = empty[Int.random(in: 1...2)] // index out of range
    }

    static func crashException() {
        Apparent.screen("about_to_crash")
        NSException(name: .invalidArgumentException, reason: "Example crash", userInfo: nil).raise()
    }
}
