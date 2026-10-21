import CryptoKit
import Foundation

/// A P-256 public key in JWK form. A JWK that carries a private part (`d`) is refused.
public struct PublicJWK: Equatable, Sendable {
    public let x: String
    public let y: String

    public init(x: String, y: String) throws {
        // The uncompressed (X9.63) form is checked to be a point on the curve; `rawRepresentation` is not.
        guard let xBytes = Base64URL.decode(x), let yBytes = Base64URL.decode(y), xBytes.count == 32, yBytes.count == 32,
              (try? P256.Signing.PublicKey(x963Representation: Data([4]) + xBytes + yBytes)) != nil else {
            throw VerificationError.malformed("public key is not a P-256 point")
        }
        self.x = x
        self.y = y
    }

    init(json: JSONValue?) throws {
        guard let object = json?.objectValue, object["kty"] == .string("EC"), object["crv"] == .string("P-256"),
              object["d"] == nil, let x = object["x"]?.stringValue, let y = object["y"]?.stringValue else {
            throw VerificationError.malformed("public key must be an EC P-256 JWK without a private part")
        }
        try self.init(x: x, y: y)
    }

    init(_ key: P256.Signing.PublicKey) {
        let raw = key.rawRepresentation
        x = Base64URL.encode(raw.prefix(32))
        y = Base64URL.encode(raw.suffix(32))
    }

    var signingKey: P256.Signing.PublicKey {
        // Validated in init.
        try! P256.Signing.PublicKey(x963Representation: Data([4]) + Base64URL.decode(x)! + Base64URL.decode(y)!)
    }

    /// The JSON the client sends as `device_public_key`: keys in sorted order, as the server's `stableJson`.
    public var canonicalJSON: String {
        #"{"crv":"P-256","kty":"EC","x":"\#(x)","y":"\#(y)"}"#
    }

    /// The server's device thumbprint for this key: `sha256:` + base64url(SHA-256(canonical JSON)).
    public var thumbprint: String {
        "sha256:" + Base64URL.encode(Data(SHA256.hash(data: Data(canonicalJSON.utf8))))
    }
}
