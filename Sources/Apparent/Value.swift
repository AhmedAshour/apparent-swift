import Foundation

/// A property value: text, a number, true/false, or nothing. Write them as literals:
/// `["source": "onboarding", "count": 3, "price": 4.99, "trial": true, "coupon": nil]`.
public enum ApparentValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
}

extension ApparentValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
}

public extension ApparentValue {
    /// Any value, never failing: strings, numbers and booleans as they are; a date as its ISO time
    /// ("2026-10-24T10:00:00.000Z"); a URL as its text; an integer too big for `Int` as its digits; arrays and
    /// dictionaries as their JSON text; anything else as its description. Text is cut to 500 characters when sent.
    init(_ any: Any?) {
        guard let any, let value = unwrapOptional(any) else { self = .null; return }
        switch value {
        case let v as ApparentValue: self = v
        case let v as String: self = .string(v)
        case let v as Substring: self = .string(String(v))
        case is NSNull: self = .null
        case let v as NSNumber where type(of: value) is NSNumber.Type:
            // Foundation's numbers (from JSONSerialization, UserDefaults, Objective-C).
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else if CFNumberIsFloatType(v) { self = .double(v.doubleValue) }
            else if String(cString: v.objCType) == "Q", v.uint64Value > UInt64(Int.max) { self = .string(v.stringValue) }
            else { self = .int(v.intValue) }
        case let v as Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as Float: self = .double(Double(v))
        case let v as Decimal: self = .double(NSDecimalNumber(decimal: v).doubleValue)
        case let v as any BinaryInteger:
            if let i = Int(exactly: v) { self = .int(i) } else { self = .string(String(describing: v)) }
        case let v as Date: self = v.timeIntervalSince1970.isFinite ? .string(isoTime(v)) : .null
        case let v as URL: self = .string(v.absoluteString)
        case let v as UUID: self = .string(v.uuidString)
        case let v as [Any]: self = .string(jsonText(v) ?? String(describing: v))
        case let v as [String: Any]: self = .string(jsonText(v) ?? String(describing: v))
        default: self = .string(String(describing: value))
        }
    }
}

/// `Optional<Optional<…>>` stored in an `Any`, unwrapped; nil when it is `.none`.
private func unwrapOptional(_ any: Any) -> Any? {
    let m = Mirror(reflecting: any)
    guard m.displayStyle == .optional else { return any }
    guard let inner = m.children.first?.value else { return nil }
    return unwrapOptional(inner)
}

/// Like JavaScript's `Date.toISOString()`: UTC, milliseconds, a "Z".
func isoTime(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    f.timeZone = TimeZone(identifier: "UTC")
    return f.string(from: date)
}

/// JSON text of an array or a dictionary, with values flattened like property values. nil when it can't be written.
private func jsonText(_ any: Any) -> String? {
    func json(_ v: Any, depth: Int) -> JSON {
        guard depth < 20, let v = unwrapOptional(v) else { return .null }
        if let a = v as? [Any] { return .array(a.map { json($0, depth: depth + 1) }) }
        if let o = v as? [String: Any] { return .object(o.mapValues { json($0, depth: depth + 1) }) }
        return JSON(ApparentValue(v))
    }
    return json(any, depth: 0).text
}

public typealias ApparentProperties = [String: ApparentValue]

/// The limits the Expo SDK applies on the phone, before anything is saved.
enum Limits {
    static let maxProps = 40
    static let maxValue = 500
    static let maxKey = 64
    static let maxName = 80
    static let maxId = 128
    static let maxBatch = 100
    static let maxEventAgeMs: Int64 = 7 * 24 * 3600_000
    static let maxErrorsPerVisit = 20
}

extension String {
    /// The first `n` UTF-16 units, like JavaScript's `slice(0, n)` (never splits a character in two).
    func cut(_ n: Int) -> String {
        if utf16.count <= n { return self }
        var out = ""
        var count = 0
        for ch in self {
            let w = ch.utf16.count
            if count + w > n { break }
            out.append(ch)
            count += w
        }
        return out
    }
}

func cleanValue(_ v: ApparentValue) -> ApparentValue {
    switch v {
    case .double(let d): return d.isFinite ? .double(d) : .null
    case .string(let s): return .string(s.cut(Limits.maxValue))
    default: return v
    }
}

/// Up to 40 properties, keys cut to 64 and text to 500 characters. `nil` when nothing is left.
func cleanProps(_ input: [(String, ApparentValue)]) -> [String: ApparentValue]? {
    var out: [String: ApparentValue] = [:]
    var order: [String] = []
    for (k, raw) in input {
        let key = k.cut(Limits.maxKey)
        if out[key] == nil {
            if order.count >= Limits.maxProps { continue }
            order.append(key)
        }
        out[key] = cleanValue(raw)
    }
    return out.isEmpty ? nil : out
}

/// A tiny JSON value with a stable writer, so what is saved and sent is exactly what we built.
indirect enum JSON: Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(_ v: ApparentValue) {
        switch v {
        case .string(let s): self = .string(s)
        case .int(let i): self = .int(Int64(i))
        case .double(let d): self = d.isFinite ? .double(d) : .null
        case .bool(let b): self = .bool(b)
        case .null: self = .null
        }
    }

    var apparentValue: ApparentValue? {
        switch self {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(Int(truncatingIfNeeded: i))
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        default: return nil
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    /// A string that isn't empty and at most `max` UTF-16 units, else nil.
    func text(max: Int) -> String? {
        guard case .string(let s) = self, !s.isEmpty, s.utf16.count <= max else { return nil }
        return s
    }
    var int64: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite: return Int64(d)
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let o) = self { return o }; return nil }

    static func parse(_ data: Data) -> JSON? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: any)
    }

    init(any: Any) {
        switch any {
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { self = .bool(n.boolValue) }
            else if CFNumberIsFloatType(n) {
                let d = n.doubleValue
                self = d.rounded() == d && abs(d) < 9e15 ? .int(Int64(d)) : .double(d)
            } else { self = .int(n.int64Value) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let o as [String: Any]: self = .object(o.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    var data: Data { Data(text.utf8) }

    var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if !d.isFinite { out += "null" }
            else if d.rounded() == d && abs(d) < 9e15 { out += String(Int64(d)) }
            else { out += "\(d)" }
        case .string(let s): JSON.quote(s, into: &out)
        case .array(let a):
            out += "["
            for (n, v) in a.enumerated() {
                if n > 0 { out += "," }
                v.write(into: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (n, k) in o.keys.sorted().enumerated() {
                if n > 0 { out += "," }
                JSON.quote(k, into: &out)
                out += ":"
                o[k]!.write(into: &out)
            }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029:
                out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        out += "\""
    }
}
