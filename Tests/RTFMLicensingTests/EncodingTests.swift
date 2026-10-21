import Foundation
import XCTest
@testable import RTFMLicensing

final class EncodingTests: XCTestCase {
    func testBase64URLIsStrict() {
        XCTAssertEqual(Base64URL.decode("-_8"), Data([0xFB, 0xFF]))
        XCTAssertEqual(Base64URL.encode(Data([0xFB, 0xFF])), "-_8")
        for bad in ["+/8", "-_8=", "-_ 8", "A"] { XCTAssertNil(Base64URL.decode(bad), bad) }
    }

    func testJSONKeepsBooleansIntegersAndStringsApart() throws {
        let value = try JSONValue.parse(Data(#"{"a":true,"b":1,"c":"1","d":1.5,"e":9007199254740993}"#.utf8))
        let object = try XCTUnwrap(value.objectValue)
        XCTAssertEqual(object["a"], .bool(true))
        XCTAssertEqual(object["b"]?.safeInteger, 1)
        XCTAssertNil(object["c"]?.safeInteger)
        XCTAssertNil(object["d"]?.safeInteger)
        XCTAssertNil(object["e"]?.safeInteger, "beyond the integers JavaScript represents exactly")
    }

    func testDeviceThumbprintMatchesTheServer() throws {
        // Expected value computed with the server's `stableJson` and `sha256Base64Url`.
        let key = try PublicJWK(x: "jQNM0huq222eftfUUjLqkR_ln4PIhxNYjXw04WGLQm4", y: "odtYB5gf5IkCdS5ME9dLT2i67O_4P7OgzCdUUEQ2VM0")
        XCTAssertEqual(key.thumbprint, "sha256:jFiTo_MCYQh1NttE1fQKtLQTIu4UJyTH9z_WGLlTJ1M")
    }

    func testPublicKeysMustBeP256PointsWithoutAPrivatePart() throws {
        let key = TestSigner().publicJWK
        XCTAssertThrowsError(try PublicJWK(x: key.x, y: key.x))
        XCTAssertThrowsError(try PublicJWK(json: .object(["kty": .string("EC"), "crv": .string("P-256"),
                                                          "x": .string(key.x), "y": .string(key.y), "d": .string("secret")])))
    }

    func testAppIntegrationFile() throws {
        let root = TestSigner().publicJWK
        let integration = try syntheticIntegration(root: root, tenantID: nil)
        XCTAssertEqual(integration.issuer, "https://synthetic-license.invalid")
        XCTAssertNil(integration.tenantID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: json([
            "schema": "rtfm.app-integration.v1", "environment": "synthetic", "apiBaseUrl": "http://synthetic-license.invalid",
            "productCode": "p", "productVersionCode": "v", "rootKeyId": "r",
            "rootPublicJwk": ["kty": "EC", "crv": "P-256", "x": root.x, "y": root.y],
        ])) as? [String: Any])
        XCTAssertThrowsError(try AppIntegration(json: json(object)), "http is refused")
        object["apiBaseUrl"] = "https://synthetic-license.invalid"
        XCTAssertNoThrow(try AppIntegration(json: json(object)))
        object["schema"] = "rtfm.app-integration.v2"
        XCTAssertThrowsError(try AppIntegration(json: json(object)), "unknown schema")
    }
}
