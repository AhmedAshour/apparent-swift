import Apparent
import SwiftUI

struct ContentView: View {
    @State private var signedIn = false
    @State private var optedOut = Apparent.isOptedOut

    var body: some View {
        NavigationView {
            List {
                Section("Events") {
                    Button("Track paywall_view") { Apparent.track("paywall_view", properties: ["source": "example"]) }
                    NavigationLink("Open the practice screen") { PracticeView() }
                    Button("Send now") { Task { await Apparent.flush() } }
                }
                Section("Person") {
                    Button(signedIn ? "Sign out" : "Sign in as user-1") {
                        if signedIn { Apparent.logout() } else { Apparent.identify(userID: "user-1") }
                        signedIn.toggle()
                    }
                    Toggle("Opted out", isOn: $optedOut)
                        .onChange(of: optedOut) { out in out ? Apparent.optOut() : Apparent.optIn() }
                    Text(Apparent.anonymousID).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                Section("Crashes (sent on the next launch)") {
                    Button("Report an error") { Apparent.captureError(URLError(.notConnectedToInternet)) }
                    Button("Crash: Swift runtime error", role: .destructive) {
                        let empty: [Int] = []
                        _ = empty[Int.random(in: 1...2)]
                    }
                    Button("Crash: NSException", role: .destructive) {
                        NSException(name: .invalidArgumentException, reason: "Example crash", userInfo: nil).raise()
                    }
                }
            }
            .navigationTitle("Apparent")
        }
        .apparentScreen("home")
    }
}

struct PracticeView: View {
    var body: some View {
        Text("Practice")
            .apparentScreen("practice", properties: ["topic": "example"])
    }
}
