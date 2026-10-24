import Foundation
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

// MARK: - Storage

/// Where the ids and the offline queue are kept. The default is a file in Application Support.
public protocol ApparentStorage: AnyObject, Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ data: Data)
    func remove(_ name: String)
}

/// Files in `Application Support/<bundle id>/Apparent/`, written atomically (where AsyncStorage keeps the Expo SDK's queue).
public final class FileStorage: ApparentStorage, @unchecked Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent(Bundle.main.bundleIdentifier ?? "app", isDirectory: true)
                .appendingPathComponent("Apparent", isDirectory: true)
        }
    }

    public func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    public func read(_ name: String) -> Data? { try? Data(contentsOf: url(name)) }

    public func write(_ name: String, _ data: Data) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(name), options: [.atomic])
    }

    public func remove(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }
}

// MARK: - Transport

public enum TransportResult: Sendable, Equatable {
    /// The server answered with this status.
    case status(Int, retryAfter: String?)
    /// No answer: offline, timed out, cancelled.
    case failed
}

/// Sends one batch. Swappable for tests and for a local intake.
public protocol ApparentTransport: Sendable {
    func post(_ url: URL, body: Data, timeout: TimeInterval, completion: @escaping @Sendable (TransportResult) -> Void)
}

public struct URLSessionTransport: ApparentTransport {
    let session: URLSession

    public init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    public func post(_ url: URL, body: Data, timeout: TimeInterval, completion: @escaping @Sendable (TransportResult) -> Void) {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.httpBody = body
        session.dataTask(with: req) { _, response, error in
            if error != nil { return completion(.failed) }
            guard let http = response as? HTTPURLResponse else { return completion(.failed) }
            completion(.status(http.statusCode, retryAfter: http.value(forHTTPHeaderField: "retry-after")))
        }.resume()
    }
}

// MARK: - Device

enum DeviceInfo {
    static func read(bundle: Bundle = .main) -> Device {
        let info = bundle.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let os = v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
        return Device(
            platform: platform,
            os: os,
            app: info["CFBundleShortVersionString"] as? String,
            build: info["CFBundleVersion"] as? String,
            model: model,
            locale: Locale.preferredLanguages.first,
            region: region,
            tz: TimeZone.current.identifier,
            simulator: isSimulator
        )
    }

    /// A Mac: a macOS app, Mac Catalyst, or an iPhone/iPad app running on an Apple silicon Mac.
    static var isMac: Bool {
        #if os(macOS) || targetEnvironment(macCatalyst)
        return true
        #else
        if #available(iOS 14, *) { return ProcessInfo.processInfo.isiOSAppOnMac }
        return false
        #endif
    }

    static var platform: String {
        isMac ? "macos" : "ios" // iPhone and iPad are "ios", like React Native's Platform.OS
    }

    /// True in the iOS Simulator (sent as `d.simulator`, so Apparent leaves it out of the counts).
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// "iPhone15,2" like Mixpanel's $model and expo-device. The iOS Simulator says the Mac's processor ("arm64"),
    /// which is how the server knows it's a test phone, so it is sent as it is. On a Mac: "Mac14,3" (hw.model).
    static var model: String? {
        isMac ? sysctl("hw.model") : sysctl("hw.machine")
    }

    static var region: String? {
        if #available(iOS 16, macOS 13, *) { return Locale.current.region?.identifier }
        return Locale.current.regionCode
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        let s = String(cString: buf)
        return s.isEmpty ? nil : s
    }
}

// MARK: - App state

enum AppState { case active, inactive, background }

/// Tells the client when the app comes to the front or goes away, and keeps the app alive while the last batch leaves.
/// Notifications arrive on the main thread; nothing here ever waits for the SDK's queue (no deadlocks).
final class Lifecycle {
    private var tokens: [NSObjectProtocol] = []

    /// The app's state right now, read on the main thread. A launch in the background is not a visit.
    static func current() -> AppState {
        #if canImport(UIKit) && !os(watchOS)
        guard Thread.isMainThread, !isAppExtension else { return .active }
        return MainActor.assumeIsolated {
            switch UIApplication.shared.applicationState {
            case .active: return .active
            case .background: return .background
            default: return .inactive
            }
        }
        #else
        return .active
        #endif
    }

    static var isAppExtension: Bool { Bundle.main.bundlePath.hasSuffix(".appex") }

    /// `handler` gets the new state and, when the app went to the background, a closure to call once sending is done.
    func observe(_ handler: @escaping (AppState, (() -> Void)?) -> Void) {
        let nc = NotificationCenter.default
        #if canImport(UIKit) && !os(watchOS)
        tokens.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in handler(.active, nil) })
        tokens.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: nil) { _ in handler(.inactive, nil) })
        tokens.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { _ in
            handler(.background, Lifecycle.beginBackgroundTask())
        })
        tokens.append(nc.addObserver(forName: UIApplication.willTerminateNotification, object: nil, queue: nil) { _ in handler(.background, nil) })
        #elseif canImport(AppKit)
        // A Mac app is "away" when it is hidden or another app is in front.
        tokens.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in handler(.active, nil) })
        tokens.append(nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { _ in handler(.background, nil) })
        tokens.append(nc.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in handler(.background, nil) })
        #endif
    }

    func stop() {
        for t in tokens { NotificationCenter.default.removeObserver(t) }
        tokens = []
    }

    /// Asks iOS for a little time to finish sending after the app went to the background. Call on the main thread;
    /// the returned closure ends it (from any thread, once).
    static func beginBackgroundTask() -> (() -> Void)? {
        #if canImport(UIKit) && !os(watchOS)
        guard Thread.isMainThread, !isAppExtension else { return nil }
        return MainActor.assumeIsolated {
            let app = UIApplication.shared
            let box = TaskBox()
            box.id = app.beginBackgroundTask(withName: "apparent-flush") { box.end() }
            return { box.end() }
        }
        #else
        return nil
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
private final class TaskBox: @unchecked Sendable {
    var id = UIBackgroundTaskIdentifier.invalid
    private var ended = false
    private let lock = NSLock()

    func end() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        guard first else { return }
        let id = self.id
        DispatchQueue.main.async { if id != .invalid { UIApplication.shared.endBackgroundTask(id) } }
    }
}
#endif
