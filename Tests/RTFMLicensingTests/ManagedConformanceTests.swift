import Foundation
import XCTest
@testable import RTFMLicensing

/// Runs every case in `managed_native_online_conformance_v1.json` through the SDK's verifier, the same cases the
/// server repository's illustrative verifier runs.
final class ManagedConformanceTests: XCTestCase {
    let manifestType = "rtfm.product-verification-key-manifest.v1+jws"
    let leaseType = "rtfm.license-lease.v1+jws"

    func testEveryCase() async throws {
        let data = try fixture("managed_native_online_conformance_v1")
        let config = try XCTUnwrap(data["public_integration"] as? [String: Any])
        let claims = try XCTUnwrap(data["signed_paid_claims"] as? [String: Any])
        let cases = try XCTUnwrap(data["cases"] as? [[String: Any]])
        XCTAssertEqual(Set(cases.compactMap { $0["id"] as? String }).count, cases.count)
        let root = TestSigner(), lease = TestSigner(), other = TestSigner()
        for entry in cases {
            let id = try XCTUnwrap(entry["id"] as? String)
            let accepted = try check(entry, config: config, claims: claims, root: root, lease: lease, other: other)
            XCTAssertEqual(accepted, entry["accepted"] as? Bool, id)
        }
    }

    private func check(_ entry: [String: Any], config: [String: Any], claims base: [String: Any],
                       root: TestSigner, lease: TestSigner, other: TestSigner) throws -> Bool {
        let change = entry["change"] as! String
        let at = Int64(entry["at"] as! Int)
        let leaseKid = change == "unknown_kid" ? "unknown-lease-key" : config["lease_kid"] as! String
        var keys: [[String: Any]] = [["kid": config["lease_kid"]!, "status": "active", "jwk": lease.jwkObject]]
        if change == "rotated_kid" || change == "unknown_kid" {
            keys.insert(["kid": "retired-key", "status": "retired", "jwk": other.jwkObject], at: 0)
        }
        let manifest: [String: Any] = [
            "schema": "rtfm.product-verification-key-manifest.v1",
            "issuer": change == "wrong_issuer" ? "https://other.invalid" : config["issuer"]!,
            "environment": change == "wrong_environment" ? "other" : config["environment"]!,
            "product_id": change == "manifest_product" ? "other-product" : config["product_id"]!,
            "generated_at": "2026-07-29T12:00:00.000Z", "keys": keys,
        ]
        var claims = base
        claims["iss"] = change == "wrong_lease_issuer" ? "https://other.invalid" : config["issuer"]!
        claims["tenant_id"] = config["tenant_id"]!
        claims["product_id"] = config["product_id"]!
        claims["release_family_id"] = config["release_family_id"]!
        claims["device_thumbprint"] = config["device_thumbprint"]!
        claims["kid"] = leaseKid
        claims["license_id"] = "lic_synthetic"
        claims["activation_id"] = "act_synthetic"
        if change == "malformed_entitlement_type", var list = claims["entitlements"] as? [[String: Any]] {
            list[1] = ["code": "activation.limit", "type": "integer", "value": "3"]
            claims["entitlements"] = list
        }
        var leaseJws = try lease.sign(kid: leaseKid, type: leaseType, payload: claims)
        if change == "tamper_lease_signature" {
            let parts = leaseJws.split(separator: ".").map(String.init)
            leaseJws = parts[0] + "." + parts[1] + "." + (parts[2].hasPrefix("A") ? "B" : "A") + parts[2].dropFirst()
        }
        let integration = try syntheticIntegration(
            root: change == "untrusted_root" ? other.publicJWK : root.publicJWK,
            tenantID: change == "tenant_scope" ? "other-tenant" : config["tenant_id"] as? String,
            productVersionCode: change == "version_scope" ? "other-version" : config["release_family_id"] as! String)
        let highWater = HighWater(sequence: change == "sequence_high_water" ? 3 : 2,
                                  revocationEpoch: change == "stale_revocation_epoch" ? 1 : 0,
                                  observedTime: change == "clock_high_water" ? at + 1 : at)
        let expectations = LeaseExpectations(
            integration: integration,
            deviceThumbprint: change == "device_scope" ? "other-device" : config["device_thumbprint"] as! String,
            highWater: highWater)
        do {
            let verified = try VerificationManifest(
                jws: try root.sign(kid: config["root_kid"] as! String, type: manifestType, payload: manifest),
                integration: integration)
            let result = try LeaseVerifier.verify(leaseJws, as: .paid, manifest: verified, expectations: expectations)
            XCTAssertEqual(result.entitlements, [
                Entitlement(code: "app.major_family", value: .string("synthetic-audio-1")),
                Entitlement(code: "activation.limit", value: .integer(3)),
                Entitlement(code: "feature.spatial", value: .boolean(true)),
            ])
            // The fixture labels a failed durable commit as a decision input; the store itself is tested in M2.
            if change == "durable_commit_failure" { return false }
            let network: AccessTiming.Network = switch entry["outcome"] as! String {
            case "network_unavailable": .unavailable
            case "available": .available
            default: .notChecked
            }
            let decision = AccessTiming.decide(result, now: at, observedTime: highWater.observedTime, network: network)
            return decision == .valid || decision == .grace
        } catch is VerificationError {
            return false
        }
    }
}
