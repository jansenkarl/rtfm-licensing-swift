import Foundation
import XCTest
@testable import RTFMLicensing

/// Runs the `key_rotation` cases of `managed_native_online_conformance_v1.json`.
final class KeyRotationTests: XCTestCase {
    struct Unreachable: Error {}

    func testEveryCase() async throws {
        let rotation = try XCTUnwrap(try fixture("managed_native_online_conformance_v1")["key_rotation"] as? [String: Any])
        let kids = try XCTUnwrap(rotation["kids"] as? [String: String])
        let cases = try XCTUnwrap(rotation["cases"] as? [[String: Any]])
        let root = TestSigner(), otherRoot = TestSigner()
        let signers = Dictionary(uniqueKeysWithValues: kids.keys.map { ($0, TestSigner()) })
        let integration = try syntheticIntegration(root: root.publicJWK)
        func manifest(_ spec: [String: Any], signedBy signer: TestSigner) throws -> VerificationManifest {
            let keys = (spec["keys"] as! [String: String]).sorted { $0.key < $1.key }.map { name, status in
                ["kid": kids[name]!, "status": status, "jwk": signers[name]!.jwkObject] as [String: Any]
            }
            let payload: [String: Any] = [
                "schema": "rtfm.product-verification-key-manifest.v1", "issuer": "https://synthetic-license.invalid",
                "environment": "synthetic", "product_id": "synthetic-audio", "generated_at": spec["generated_at"]!, "keys": keys,
            ]
            return try VerificationManifest(jws: signer.sign(kid: "synthetic-root-v1", type: "rtfm.product-verification-key-manifest.v1+jws",
                                                             payload: payload), integration: integration)
        }
        let now = Date(timeIntervalSince1970: 1_785_499_200)
        for entry in cases {
            let id = entry["id"] as! String
            let expected = entry["expected"] as! [String: Any]
            let held = try manifest(entry["cached"] as! [String: Any], signedBy: root)
            var fetches = 0
            let last = (entry["last_refetch_seconds_ago"] as? Int).map { now.addingTimeInterval(-Double($0)) }
            let outcome = await KeyRotation.resolve(kid: kids[entry["lease_key"] as! String]!, held: held,
                                                    lastRefetchForKid: last, now: now) {
                fetches += 1
                guard let spec = entry["refetch"] as? [String: Any] else { throw Unreachable() }
                return try manifest(spec, signedBy: spec["signed_by"] as? String == "pinned_root" ? root : otherRoot)
            }
            XCTAssertEqual(outcome.key != nil, expected["accepted"] as? Bool, id)
            XCTAssertEqual(fetches, expected["fetches"] as? Int, id)
            XCTAssertEqual(outcome.fetched, fetches > 0, id)
            XCTAssertEqual(outcome.manifest.generatedAt, Timestamp.parse(expected["generated_at_after"] as! String), id)
        }
    }
}
