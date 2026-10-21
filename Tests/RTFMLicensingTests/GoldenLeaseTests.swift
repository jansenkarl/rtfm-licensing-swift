import Foundation
import XCTest
@testable import RTFMLicensing

/// Verifies leases signed by the server's own JWS code (the golden fixtures), so the SDK and the server agree on
/// encoding, signatures and claims, not only on synthetic leases signed in these tests.
final class GoldenLeaseTests: XCTestCase {
    private func golden(_ name: String) throws -> (jws: String, kid: String, key: PublicJWK, payload: [String: Any]) {
        let data = try fixture(name)
        let jwk = try XCTUnwrap(data["public_jwk"] as? [String: Any])
        return (data["jws"] as! String, data["key_id"] as! String,
                try PublicJWK(x: jwk["x"] as! String, y: jwk["y"] as! String), data["expected_payload"] as! [String: Any])
    }

    private func staging(tenant: String = "tenant_rtfm_design") throws -> AppIntegration {
        let root = TestSigner().publicJWK
        return try AppIntegration(json: json([
            "schema": "rtfm.app-integration.v1", "environment": "staging", "apiBaseUrl": "https://license-api-staging.rtfmdesign.com",
            "productCode": "rtfm-player", "productVersionCode": "rtfm-1", "rootKeyId": "root",
            "rootPublicJwk": ["kty": "EC", "crv": "P-256", "x": root.x, "y": root.y], "tenantId": tenant,
        ]))
    }

    private func verify(_ name: String, as kind: LeaseVerifier.Expected, tenant: String = "tenant_rtfm_design") throws -> Lease {
        let fixture = try golden(name)
        let manifest = VerificationManifest(generatedAt: Date(), keys: [ManifestKey(kid: fixture.kid, status: "active", publicKey: fixture.key)])
        let expectations = LeaseExpectations(integration: try staging(tenant: tenant),
                                             deviceThumbprint: fixture.payload["device_thumbprint"] as! String,
                                             highWater: HighWater(sequence: 1, trialRevision: 1))
        return try LeaseVerifier.verify(fixture.jws, as: kind, manifest: manifest, expectations: expectations)
    }

    func testServerSignedPayloadsDecodeExactly() throws {
        for name in ["paid_lease_valid_p256_es256", "paid_lease_custom_entitlements_valid_p256_es256", "trial_lease_valid_p256_es256"] {
            let fixture = try golden(name)
            let type = name.hasPrefix("trial") ? "rtfm.trial-lease.v1+jws" : "rtfm.license-lease.v1+jws"
            let payload = try CompactJWS.verify(fixture.jws, key: fixture.key, kid: fixture.kid, type: type)
            XCTAssertEqual(JSONValue.object(payload), try JSONValue.parse(json(fixture.payload)), name)
        }
    }

    func testPaidLease() throws {
        let lease = try verify("paid_lease_valid_p256_es256", as: .paid)
        XCTAssertEqual(lease.kind, .paid(licenseID: "lic_golden_paid_001", activationID: "act_golden_paid_001", revocationEpoch: 0))
        XCTAssertEqual(lease.entitlements, [Entitlement(code: "app.major_family", value: .string("rtfm-1")),
                                            Entitlement(code: "activation.limit", value: .integer(5))])
        XCTAssertEqual([lease.refreshAfter, lease.expiresAt, lease.graceUntil], [1_785_902_400, 1_793_073_600, 1_794_283_200])
    }

    func testTypedCustomEntitlements() throws {
        let lease = try verify("paid_lease_custom_entitlements_valid_p256_es256", as: .paid)
        XCTAssertEqual(lease.entitlements.map(\.code), ["app.major_family", "activation.limit", "qa.option4.boolean",
                                                         "qa.option4.datetime", "qa.option4.integer", "qa.option4.string"])
        XCTAssertEqual(lease.entitlements[3].value, .dateTime(Timestamp.parse("2027-08-04T00:00:00.000Z")!))
        XCTAssertEqual(lease.entitlements[5].value, .string("studio"))
    }

    func testTrialLease() throws {
        let lease = try verify("trial_lease_valid_p256_es256", as: .trial)
        XCTAssertEqual(lease.kind, .trial(trialID: "trl_golden_trial_001", endsAt: Timestamp.parse("2026-08-30T12:00:00.000Z")!, revision: 1))
        XCTAssertTrue(lease.entitlements.contains(Entitlement(code: "trial", value: .boolean(true))))
    }

    func testPaidAndTrialVerifiersRefuseEachOther() throws {
        XCTAssertThrowsError(try verify("trial_lease_valid_p256_es256", as: .paid)) {
            XCTAssertEqual($0 as? VerificationError, .unexpectedHeader("typ"))
        }
        XCTAssertThrowsError(try verify("paid_lease_valid_p256_es256", as: .trial)) {
            XCTAssertEqual($0 as? VerificationError, .unexpectedHeader("typ"))
        }
    }

    func testAnotherTenantsLeaseIsRefused() throws {
        XCTAssertThrowsError(try verify("paid_lease_valid_p256_es256", as: .paid, tenant: "tenant_other")) {
            XCTAssertEqual($0 as? VerificationError, .wrongScope("lease tenant"))
        }
    }
}
