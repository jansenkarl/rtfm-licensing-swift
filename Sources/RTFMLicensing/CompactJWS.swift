import CryptoKit
import Foundation

/// ES256 compact JWS as issued by the RTFM licensing server: `header.payload.signature`, raw r||s signature.
enum CompactJWS {
    static let leaseType = "rtfm.license-lease.v1+jws"
    static let trialLeaseType = "rtfm.trial-lease.v1+jws"
    static let manifestType = "rtfm.product-verification-key-manifest.v1+jws"

    /// The header's `kid`, read before the signature is checked, only to choose which key to check it with.
    static func unverifiedKeyID(_ jws: String) throws -> String {
        let parts = try split(jws)
        guard let kid = try decodeObject(parts[0], "header")["kid"]?.stringValue, !kid.isEmpty else {
            throw VerificationError.unexpectedHeader("kid")
        }
        return kid
    }

    /// Checks the header (`alg`, `kid`, `typ`) and the signature, then returns the payload object.
    static func verify(_ jws: String, key: PublicJWK, kid: String, type: String) throws -> [String: JSONValue] {
        let parts = try split(jws)
        let header = try decodeObject(parts[0], "header")
        guard header["alg"] == .string("ES256") else { throw VerificationError.unexpectedHeader("alg") }
        guard header["kid"] == .string(kid) else { throw VerificationError.unexpectedHeader("kid") }
        guard header["typ"] == .string(type) else { throw VerificationError.unexpectedHeader("typ") }
        guard let signatureBytes = Base64URL.decode(parts[2]), signatureBytes.count == 64,
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureBytes),
              key.signingKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)) else {
            throw VerificationError.untrustedSignature
        }
        return try decodeObject(parts[1], "payload")
    }

    private static func split(_ jws: String) throws -> [String] {
        let parts = jws.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3 else { throw VerificationError.malformed("expected a compact JWS") }
        return parts
    }

    private static func decodeObject(_ part: String, _ label: String) throws -> [String: JSONValue] {
        guard let data = Base64URL.decode(part), let object = (try? JSONValue.parse(data))?.objectValue else {
            throw VerificationError.malformed("JWS \(label) must be a JSON object")
        }
        return object
    }
}
