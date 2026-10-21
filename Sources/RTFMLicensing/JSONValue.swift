import Foundation

/// A parsed JSON value that keeps booleans, integers and strings apart, so signed claims are checked by type.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    /// Integers JSON and JavaScript agree on exactly (the server issues claims from JavaScript).
    static let safeIntegerRange: ClosedRange<Int64> = -9_007_199_254_740_991 ... 9_007_199_254_740_991

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
    var objectValue: [String: JSONValue]? { if case let .object(value) = self { return value }; return nil }
    var arrayValue: [JSONValue]? { if case let .array(value) = self { return value }; return nil }
    var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }

    /// A whole number within the safe integer range; anything else (fraction, string, out of range) is nil.
    var safeInteger: Int64? {
        if case let .integer(value) = self, JSONValue.safeIntegerRange.contains(value) { return value }
        return nil
    }
}

extension JSONValue: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }
}
