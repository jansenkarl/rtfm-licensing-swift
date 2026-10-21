import Foundation

/// Verifies paid and trial leases against a verified manifest. A paid verifier refuses trial leases and the
/// reverse. Timing (expiry and grace) is decided separately by `AccessTiming`.
public enum LeaseVerifier {
    public enum Expected: Sendable { case paid, trial }

    public static func verify(_ jws: String, as expected: Expected, manifest: VerificationManifest,
                              expectations: LeaseExpectations) throws -> Lease {
        let kid = try CompactJWS.unverifiedKeyID(jws)
        guard let key = manifest.listedKey(kid) else { throw VerificationError.unknownKey(kid) }
        guard key.status == "active" else { throw VerificationError.inactiveKey(kid) }
        let type = expected == .paid ? CompactJWS.leaseType : CompactJWS.trialLeaseType
        let claims = try CompactJWS.verify(jws, key: key.publicKey, kid: kid, type: type)
        return try lease(from: claims, jws: jws, kid: kid, expected: expected, expectations: expectations)
    }

    static func lease(from claims: [String: JSONValue], jws: String, kid: String, expected: Expected,
                      expectations: LeaseExpectations) throws -> Lease {
        let integration = expectations.integration
        let schema = expected == .paid ? "rtfm.license-lease.v1" : "rtfm.trial-lease.v1"
        guard claims["schema"] == .string(schema) else { throw VerificationError.malformed("lease schema") }
        guard claims["kid"] == .string(kid) else { throw VerificationError.wrongScope("lease kid") }
        guard claims["iss"] == .string(integration.issuer) else { throw VerificationError.wrongScope("lease issuer") }
        guard let tenant = claims["tenant_id"]?.stringValue, !tenant.isEmpty,
              integration.tenantID == nil || integration.tenantID == tenant else {
            throw VerificationError.wrongScope("lease tenant")
        }
        guard claims["product_id"] == .string(integration.productCode) else {
            throw VerificationError.wrongScope("lease product")
        }
        guard claims["release_family_id"] == .string(integration.productVersionCode) else {
            throw VerificationError.wrongScope("lease product version")
        }
        guard claims["device_thumbprint"] == .string(expectations.deviceThumbprint) else {
            throw VerificationError.wrongScope("lease installation")
        }
        func integer(_ name: String) throws -> Int64 {
            guard let value = claims[name]?.safeInteger else { throw VerificationError.malformed("lease \(name)") }
            return value
        }
        func text(_ name: String) throws -> String {
            guard let value = claims[name]?.stringValue, !value.isEmpty else {
                throw VerificationError.malformed("lease \(name)")
            }
            return value
        }
        let sequence = try integer("sequence")
        let issuedAt = try integer("iat"), notBefore = try integer("nbf")
        let refreshAfter = try integer("refresh_after"), expiresAt = try integer("exp"), graceUntil = try integer("grace_until")
        guard refreshAfter <= expiresAt, expiresAt <= graceUntil else { throw VerificationError.malformed("lease timing order") }
        let highWater = expectations.highWater
        let kind: Lease.Kind
        let typed: Bool
        switch expected {
        case .paid:
            let epoch = try integer("revocation_epoch")
            let licenseID = try text("license_id"), activationID = try text("activation_id")
            if HighWater.applies(highWater.activationID, to: activationID), sequence < highWater.sequence {
                throw VerificationError.staleState("lease sequence")
            }
            if HighWater.applies(highWater.licenseID, to: licenseID), epoch < highWater.revocationEpoch {
                throw VerificationError.staleState("revocation epoch")
            }
            kind = .paid(licenseID: licenseID, activationID: activationID, revocationEpoch: epoch)
            if let revision = claims["entitlement_revision"] {
                guard revision.safeInteger != nil else { throw VerificationError.malformed("lease entitlement_revision") }
                typed = true
            } else {
                typed = false
            }
        case .trial:
            guard claims["lease_kind"] == .string("trial") else { throw VerificationError.malformed("trial lease kind") }
            let revision = try integer("trial_revision")
            let trialID = try text("trial_id")
            if HighWater.applies(highWater.trialID, to: trialID) {
                guard sequence >= highWater.trialSequence ?? 0 else { throw VerificationError.staleState("lease sequence") }
                guard revision >= highWater.trialRevision else { throw VerificationError.staleState("trial revision") }
            }
            guard let endsAt = Timestamp.parse(try text("trial_ends_at")) else {
                throw VerificationError.malformed("trial_ends_at")
            }
            guard Double(graceUntil) <= endsAt.timeIntervalSince1970 else {
                throw VerificationError.malformed("trial lease grace exceeds the trial end")
            }
            kind = .trial(trialID: trialID, endsAt: endsAt, revision: revision)
            typed = false
        }
        return Lease(kind: kind, jws: jws, keyID: kid, sequence: sequence, issuedAt: issuedAt, notBefore: notBefore,
                     refreshAfter: refreshAfter, expiresAt: expiresAt, graceUntil: graceUntil,
                     entitlements: try Entitlement.parseList(claims["entitlements"], typed: typed),
                     term: try term(claims["term"]))
    }

    /// The optional `term` claim of a fixed-term or subscription key.
    static func term(_ value: JSONValue?) throws -> Lease.Term? {
        guard let value else { return nil }
        guard let object = value.objectValue, let kind = object["type"]?.stringValue.flatMap(Lease.Term.Kind.init),
              let endsAt = object["ends_at"]?.stringValue.flatMap(Timestamp.parse),
              let accessEndsAt = object["access_ends_at"]?.stringValue.flatMap(Timestamp.parse), accessEndsAt >= endsAt else {
            throw VerificationError.malformed("lease term")
        }
        return Lease.Term(kind: kind, endsAt: endsAt, accessEndsAt: accessEndsAt)
    }
}
