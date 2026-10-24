import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Crashes: an uncaught Objective-C exception or a crash signal (SIGSEGV, SIGABRT, Swift's runtime traps…) is written
/// to a file as the app goes down, and sent on the next launch as an `error` event with `fatal: true, how: "crash"`,
/// the same as the Expo SDK's crashes. Whatever handler was there before (another crash reporter) still runs after.
final class CrashReporter: @unchecked Sendable {
    static let exceptionFile = "crash-exception.json"
    static let signalFile = "crash-signal.json"
    static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    let directory: URL
    private let lock = NSLock()
    private var context = JSON.object([:])
    /// Saves the queue before an uncaught exception ends the app (not for signals: nothing safe can be done there).
    var saveBeforeCrash: (() -> Void)?

    private static var installed: CrashReporter?

    private init(directory: URL) { self.directory = directory }

    /// One reporter per process; the first `start` wins.
    static func install(directory: URL) -> CrashReporter {
        if let installed { return installed }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let r = CrashReporter(directory: directory)
        installed = r
        crashSignalPath = strdup(directory.appendingPathComponent(signalFile).path)
        crashContextBuffers = (UnsafeMutablePointer<UInt8>.allocate(capacity: contextCapacity), UnsafeMutablePointer<UInt8>.allocate(capacity: contextCapacity))
        crashScratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 32)
        storeContext(Data("{}".utf8))
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler { exception in CrashReporter.installed?.exceptionCaught(exception) }
        hasPreviousSignalAction.initialize(repeating: false, count: 64)
        for sig in signals {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = apparentSignalHandler
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            var old = sigaction()
            if sigaction(sig, &action, &old) == 0 { previousSignalActions[Int(sig)] = old; hasPreviousSignalAction[Int(sig)] = true }
        }
        return r
    }

    /// Who and where, kept ready so a crash can be written without building anything.
    func setContext(session: String, anon: String, user: String?, screen: String?) {
        var o: [String: JSON] = ["s": .string(session), "a": .string(anon), "u": user.map(JSON.string) ?? .null]
        if let screen { o["screen"] = .string(screen) }
        let ctx = JSON.object(o)
        lock.lock()
        context = ctx
        lock.unlock()
        storeContext(ctx.data)
    }

    func exceptionCaughtForTests(_ exception: NSException) { exceptionCaught(exception, passOn: false) }

    private func exceptionCaught(_ exception: NSException, passOn: Bool = true) {
        crashExceptionWritten = 1
        let ctx: JSON
        if lock.try() { ctx = context; lock.unlock() } else { ctx = .object([:]) }
        let stack = exception.callStackSymbols.prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
        let record = JSON.object([
            "t": .int(nowMs()), "type": .string(exception.name.rawValue), "message": .string(exception.reason ?? exception.name.rawValue),
            "stack": .string(stack), "ctx": ctx,
        ])
        try? record.data.write(to: directory.appendingPathComponent(Self.exceptionFile))
        saveBeforeCrash?()
        if passOn { previousExceptionHandler?(exception) }
    }

    /// The crash from the last run as an event, then forgets it. `props` = the properties saved with the queue.
    func takeReport(props: [String: ApparentValue]) -> Queued? {
        let exURL = directory.appendingPathComponent(Self.exceptionFile)
        let sigURL = directory.appendingPathComponent(Self.signalFile)
        defer {
            try? FileManager.default.removeItem(at: exURL)
            try? FileManager.default.removeItem(at: sigURL)
        }
        var type = "", message = "", stack: String?
        let record: JSON
        if let r = (try? Data(contentsOf: exURL)).flatMap(JSON.parse) {
            record = r
            type = r["type"]?.string ?? "NSException"
            message = r["message"]?.string ?? type
            stack = r["stack"]?.string
        } else if let r = (try? Data(contentsOf: sigURL)).flatMap(JSON.parse), let sig = r["sig"]?.int64 {
            record = r
            type = Self.signalName(Int32(sig))
            message = Self.signalMessage(Int32(sig))
        } else {
            return nil
        }
        let ctx = record["ctx"]
        var p: [(String, ApparentValue)] = props.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        p += [("message", .string(message.cut(300))), ("type", .string(type)), ("fatal", .bool(true)), ("how", .string("crash"))]
        if let stack, !stack.isEmpty { p.append(("stack", .string(stack.cut(1500)))) }
        if let screen = ctx?["screen"]?.string { p.append(("screen", .string(screen))) }
        return Queued(n: "error", t: record["t"]?.int64 ?? nowMs(), s: (ctx?["s"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? newId(), i: newId(), p: cleanProps(p),
                      a: ctx?["a"]?.string ?? "", u: ctx?["u"]?.string)
    }

    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGFPE: return "SIGFPE"
        case SIGTRAP: return "SIGTRAP"
        default: return "SIG\(sig)"
        }
    }

    static func signalMessage(_ sig: Int32) -> String {
        switch sig {
        case SIGTRAP, SIGILL: return "The app crashed: a Swift runtime error (force unwrap of nil, index out of range, fatalError…)"
        case SIGSEGV, SIGBUS: return "The app crashed: bad memory access"
        case SIGABRT: return "The app crashed: abort"
        case SIGFPE: return "The app crashed: arithmetic error"
        default: return "The app crashed (signal \(sig))"
        }
    }

    /// For tests: forget the handlers' memory of an exception.
    static func resetForTests() { crashExceptionWritten = 0 }

    /// For tests: delivers a real signal to the real handler, which writes the record and returns instead of handing
    /// the signal on (so the test process lives on).
    static func raiseForTests(_ sig: Int32) {
        // On a thread of its own: Swift concurrency's threads can't be signalled one by one.
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            crashHandlerReturnsForTests = true
            pthread_kill(pthread_self(), sig)
            crashHandlerReturnsForTests = false
            done.signal()
        }
        thread.start()
        done.wait()
    }
}

// MARK: - What the signal handler may touch: only plain memory prepared in advance (it must not allocate or lock).

private let contextCapacity = 4096
private var crashSignalPath: UnsafeMutablePointer<CChar>?
private var crashContextBuffers: (UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt8>)?
private var crashContextLengths: (Int, Int) = (0, 0)
private var crashContextActive: Int32 = 0
private var crashScratch: UnsafeMutablePointer<UInt8>?
private var crashExceptionWritten: Int32 = 0
private var crashHandlerReturnsForTests = false
private let previousSignalActions = UnsafeMutablePointer<sigaction>.allocate(capacity: 64)
private let hasPreviousSignalAction = UnsafeMutablePointer<Bool>.allocate(capacity: 64)
private var previousExceptionHandler: (@convention(c) (NSException) -> Void)?

/// Writes the context into the buffer the handler isn't reading, then flips to it.
private func storeContext(_ data: Data) {
    guard let buffers = crashContextBuffers else { return }
    let bytes = data.count <= contextCapacity ? data : Data("{}".utf8)
    let next: Int32 = crashContextActive == 0 ? 1 : 0
    let target = next == 0 ? buffers.0 : buffers.1
    bytes.copyBytes(to: target, count: bytes.count)
    if next == 0 { crashContextLengths.0 = bytes.count } else { crashContextLengths.1 = bytes.count }
    crashContextActive = next
}

private func writeStatic(_ fd: Int32, _ s: StaticString) {
    _ = write(fd, s.utf8Start, s.utf8CodeUnitCount)
}

private func writeNumber(_ fd: Int32, _ value: Int64) {
    guard let buf = crashScratch else { return }
    var v = value < 0 ? -value : value
    var i = 31
    repeat {
        buf[i] = UInt8(48 + v % 10)
        v /= 10
        i -= 1
    } while v > 0 && i > 0
    if value < 0 { buf[i] = 45; i -= 1 }
    _ = write(fd, buf + i + 1, 31 - i)
}

private func apparentSignalHandler(_ sig: Int32) {
    if crashExceptionWritten == 0, let path = crashSignalPath, let buffers = crashContextBuffers {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd >= 0 {
            var ts = timespec()
            clock_gettime(CLOCK_REALTIME, &ts)
            let ms = Int64(ts.tv_sec) * 1000 + Int64(ts.tv_nsec) / 1_000_000
            writeStatic(fd, "{\"sig\":")
            writeNumber(fd, Int64(sig))
            writeStatic(fd, ",\"t\":")
            writeNumber(fd, ms)
            writeStatic(fd, ",\"ctx\":")
            if crashContextActive == 0 { _ = write(fd, buffers.0, crashContextLengths.0) } else { _ = write(fd, buffers.1, crashContextLengths.1) }
            writeStatic(fd, "}")
            close(fd)
        }
    }
    if crashHandlerReturnsForTests { return }
    // Hand the signal on to whoever had it before (or the system), so the crash goes on as it would have.
    if sig >= 0 && sig < 64 && hasPreviousSignalAction[Int(sig)] { sigaction(sig, previousSignalActions + Int(sig), nil) } else { signal(sig, SIG_DFL) }
    raise(sig)
}
