import Foundation

/// A dynamic JSON value.
///
/// The T3 wire schema is large and changes between releases. The bridge decodes
/// frames into `JSONValue` and reads only the fields it needs, so unknown
/// fields, event types, and item types never break decoding.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

extension JSONValue {
    /// The member named `key` when the value is an object.
    public subscript(key: String) -> JSONValue? {
        if case .object(let members) = self { return members[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .number(let value) = self, value.isFinite, abs(value) < 9.0e15 { return Int(value) }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    /// The string member named `key`. Returns nil for a missing, null, or non-string member.
    public func string(_ key: String) -> String? { self[key]?.stringValue }

    /// The string member named `key` when it has visible characters.
    public func nonEmptyString(_ key: String) -> String? {
        guard let value = string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    public func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    public func int(_ key: String) -> Int? { self[key]?.intValue }
    public func double(_ key: String) -> Double? { self[key]?.doubleValue }
    public func array(_ key: String) -> [JSONValue] { self[key]?.arrayValue ?? [] }

    /// The member named `key` when it's an object.
    public func object(_ key: String) -> JSONValue? {
        guard let value = self[key], case .object = value else { return nil }
        return value
    }

    /// The member named `key` parsed as an ISO 8601 timestamp.
    public func date(_ key: String) -> Date? {
        guard let text = string(key) else { return nil }
        return JSONValue.parseDate(text)
    }

    /// Returns a copy of the object with `key` set. Other values return unchanged.
    public func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case .object(var members) = self else { return self }
        members[key] = value
        return .object(members)
    }
}

// MARK: - Dates

extension JSONValue {
    static func parseDate(_ text: String) -> Date? {
        // `Date.ISO8601FormatStyle` is a value type, so parsing stays thread-safe.
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(text)
    }

    /// Formats a timestamp the way the server does: UTC with milliseconds.
    static func formatDate(_ date: Date) -> String {
        // Round to the millisecond first. The format style truncates, which
        // turns 24.231 into 24.230 when the double sits just under the value.
        let milliseconds = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = milliseconds.quotientAndRemainder(dividingBy: 1000)
        let whole = Date(timeIntervalSince1970: TimeInterval(seconds.quotient))
        let base = whole.formatted(Date.ISO8601FormatStyle())
        return base.dropLast() + String(format: ".%03dZ", abs(seconds.remainder))
    }
}

// MARK: - Parsing and serialization

public struct JSONParseError: Error, Sendable {
    public let message: String
}

extension JSONValue {
    public static func parse(_ data: Data) throws -> JSONValue {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError(message: error.localizedDescription)
        }
        return JSONValue(foundationObject: object)
    }

    public static func parse(_ text: String) throws -> JSONValue {
        try parse(Data(text.utf8))
    }

    init(foundationObject: Any) {
        switch foundationObject {
        case let dictionary as [String: Any]:
            var members: [String: JSONValue] = [:]
            members.reserveCapacity(dictionary.count)
            for (key, value) in dictionary {
                members[key] = JSONValue(foundationObject: value)
            }
            self = .object(members)
        case let array as [Any]:
            self = .array(array.map { JSONValue(foundationObject: $0) })
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            // JSONSerialization represents booleans as the CFBoolean singletons.
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                self = .number(number.doubleValue)
            }
        default:
            self = .null
        }
    }

    var foundationObject: Any {
        switch self {
        case .null:
            return NSNull()
        case .bool(let value):
            return value
        case .number(let value):
            if value.isFinite, value == value.rounded(), abs(value) < 9.0e15 {
                return Int(value)
            }
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(\.foundationObject)
        case .object(let members):
            return members.mapValues(\.foundationObject)
        }
    }

    public func serialized(sortedKeys: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if sortedKeys { options.insert(.sortedKeys) }
        guard let data = try? JSONSerialization.data(withJSONObject: foundationObject, options: options) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(nilLiteral: ()) { self = .null }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var members: [String: JSONValue] = [:]
        for (key, value) in elements { members[key] = value }
        self = .object(members)
    }
}
