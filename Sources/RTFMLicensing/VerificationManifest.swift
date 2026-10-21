import Foundation

/// One lease-signing key listed in a Product's root-signed manifest.
public struct ManifestKey: Equatable, Sendable {
    public let kid: String
    /// Only `"active"` keys verify leases; any other status, known or not, does not.
    public let status: String
    public let publicKey: PublicJWK
}

/// A Product's lease-signing keys, accepted only after its signature checks out against the pinned root.
public struct VerificationManifest: Equatable, Sendable {
    public let generatedAt: Date
    public let keys: [ManifestKey]
    /// The signed JWS, kept so the manifest can be stored and verified again on the next launch.
    public let jws: String

    /// Verifies the `signature` field of a `GET /v1/products/{code}/verification-keys` response (or a stored JWS).
    public init(jws: String, integration: AppIntegration) throws {
        let payload = try CompactJWS.verify(jws, key: integration.rootPublicKey, kid: integration.rootKeyID,
                                            type: CompactJWS.manifestType)
        guard payload["schema"] == .string("rtfm.product-verification-key-manifest.v1") else {
            throw VerificationError.malformed("manifest schema")
        }
        guard payload["issuer"] == .string(integration.issuer) else { throw VerificationError.wrongScope("manifest issuer") }
        guard payload["environment"] == .string(integration.environment) else {
            throw VerificationError.wrongScope("manifest environment")
        }
        guard payload["product_id"] == .string(integration.productCode) else {
            throw VerificationError.wrongScope("manifest product")
        }
        guard let generated = payload["generated_at"]?.stringValue, let date = Timestamp.parse(generated) else {
            throw VerificationError.malformed("manifest generated_at")
        }
        guard let entries = payload["keys"]?.arrayValue, !entries.isEmpty else {
            throw VerificationError.malformed("manifest keys")
        }
        keys = try entries.map { entry in
            guard let object = entry.objectValue, let kid = object["kid"]?.stringValue, !kid.isEmpty,
                  let status = object["status"]?.stringValue else {
                throw VerificationError.malformed("manifest key entry")
            }
            return ManifestKey(kid: kid, status: status, publicKey: try PublicJWK(json: object["jwk"]))
        }
        generatedAt = date
        self.jws = jws
    }

    init(generatedAt: Date, keys: [ManifestKey], jws: String = "") {
        self.generatedAt = generatedAt
        self.keys = keys
        self.jws = jws
    }

    /// The listed key for `kid`, or nil when the manifest does not list it (exactly once).
    func listedKey(_ kid: String) -> ManifestKey? {
        let matching = keys.filter { $0.kid == kid }
        return matching.count == 1 ? matching[0] : nil
    }
}

enum Timestamp {
    /// ISO 8601 UTC with or without fractional seconds, as the server writes them.
    static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}
