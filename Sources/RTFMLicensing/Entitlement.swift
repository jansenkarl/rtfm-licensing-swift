import Foundation

/// A signed entitlement from a verified lease: system values such as `activation.limit`, and the publisher's
/// custom license fields.
public struct Entitlement: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case string(String)
        case integer(Int64)
        case boolean(Bool)
        case dateTime(Date)
    }

    public let code: String
    public let value: Value

    /// Typed entries (`type` present) are required once a lease carries `entitlement_revision`; older leases carry
    /// untyped `{code, value}` entries, whose type follows the JSON value.
    static func parseList(_ json: JSONValue?, typed: Bool) throws -> [Entitlement] {
        guard let items = json?.arrayValue, !items.isEmpty else { throw VerificationError.malformed("entitlements") }
        var seen = Set<String>()
        return try items.map { item in
            guard let object = item.objectValue, let code = object["code"]?.stringValue, !code.isEmpty,
                  seen.insert(code).inserted, let raw = object["value"] else {
                throw VerificationError.malformed("entitlement entry")
            }
            let type = object["type"]
            if typed {
                guard let type = type?.stringValue else { throw VerificationError.malformed("entitlement \(code) type") }
                return Entitlement(code: code, value: try typedValue(type, raw, code))
            }
            guard type == nil else { throw VerificationError.malformed("entitlement \(code) type without a revision") }
            switch raw {
            case let .string(value): return Entitlement(code: code, value: .string(value))
            case let .bool(value): return Entitlement(code: code, value: .boolean(value))
            default:
                guard let value = raw.safeInteger else { throw VerificationError.malformed("entitlement \(code) value") }
                return Entitlement(code: code, value: .integer(value))
            }
        }
    }

    private static func typedValue(_ type: String, _ raw: JSONValue, _ code: String) throws -> Value {
        switch (type, raw) {
        case let ("string", .string(value)): return .string(value)
        case let ("boolean", .bool(value)): return .boolean(value)
        case let ("datetime", .string(value)):
            guard let date = Timestamp.parse(value) else { break }
            return .dateTime(date)
        case ("integer", _):
            guard let value = raw.safeInteger else { break }
            return .integer(value)
        default: break
        }
        throw VerificationError.malformed("entitlement \(code) is not a valid \(type)")
    }
}
