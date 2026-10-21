import CryptoKit
import Foundation
import XCTest
@testable import RTFMLicensing

/// Reads a shared fixture file as plain JSON.
func fixture(_ name: String) throws -> [String: Any] {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

func json(_ object: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
}

/// An ephemeral P-256 signer standing in for the server in tests.
struct TestSigner {
    let key = P256.Signing.PrivateKey()
    var publicJWK: PublicJWK { PublicJWK(key.publicKey) }
    var jwkObject: [String: Any] { ["kty": "EC", "crv": "P-256", "x": publicJWK.x, "y": publicJWK.y] }

    func sign(kid: String, type: String, payload: [String: Any]) throws -> String {
        let header = try json(["alg": "ES256", "kid": kid, "typ": type])
        let input = Base64URL.encode(header) + "." + Base64URL.encode(try json(payload))
        let signature = try key.signature(for: Data(input.utf8))
        return input + "." + Base64URL.encode(signature.rawRepresentation)
    }
}

/// An App integration file for the synthetic publisher in the managed conformance fixture.
func syntheticIntegration(root: PublicJWK, rootKeyID: String = "synthetic-root-v1", tenantID: String? = "tenant_synthetic_publisher",
                          productVersionCode: String = "synthetic-audio-1") throws -> AppIntegration {
    var object: [String: Any] = [
        "schema": "rtfm.app-integration.v1", "environment": "synthetic", "apiBaseUrl": "https://synthetic-license.invalid",
        "productCode": "synthetic-audio", "productVersionCode": productVersionCode, "rootKeyId": rootKeyID,
        "rootPublicJwk": ["kty": "EC", "crv": "P-256", "x": root.x, "y": root.y],
    ]
    if let tenantID { object["tenantId"] = tenantID }
    return try AppIntegration(json: json(object))
}
