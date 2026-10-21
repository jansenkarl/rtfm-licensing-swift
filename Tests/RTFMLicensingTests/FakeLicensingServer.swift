import CryptoKit
import Foundation
@testable import RTFMLicensing

/// A small in-process stand-in for the licensing API: checks challenge proofs, counts seats, signs leases, and
/// replays an idempotent request's stored response. It can lose a response after doing the work, or fail.
final class FakeLicensingServer: HTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    let root = TestSigner()
    var leaseSigners = ["lease-1": TestSigner()]
    var activeKid = "lease-1"
    var manifestGeneratedAt = "2026-07-29T12:00:00.000Z"
    var seatsUsed = 0
    var mutationsReceived = 0
    var sequence: Int64 = 0
    /// Do the work, then answer as if the connection dropped.
    var loseNextResponse = false
    /// Answer the next mutation with this error instead of doing anything.
    var failNext: (status: Int, code: String, retryable: Bool)?
    var afterMutation: (() -> Void)?
    /// Signs leases for this thumbprint instead of the caller's, to simulate a mis-scoped lease.
    var overrideThumbprint: String?
    private var challenges: [String: (nonce: String, thumbprint: String, used: Bool)] = [:]
    private var replays: [String: Data] = [:]
    private var credentials: [String: String] = [:]
    var now: Int64 = 1_785_499_200
    /// Every request fails as if the Mac were offline.
    var offline = false
    /// Signed into paid leases as the `term` claim when set.
    var term: [String: Any]?

    var integration: AppIntegration { try! syntheticIntegration(root: root.publicJWK) }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try lock.withLock {
            if offline { throw URLError(.notConnectedToInternet) }
            let path = request.url!.path
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            let (status, object) = try handle(path, body, key: request.value(forHTTPHeaderField: "Idempotency-Key"))
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (try json(object), response)
        }
    }

    private func handle(_ path: String, _ body: [String: Any], key: String?) throws -> (Int, [String: Any]) {
        if path == "/v1/products/synthetic-audio/verification-keys" { return (200, ["signature": try manifest()]) }
        if path == "/v1/device-challenges" {
            let id = "chg_\(challenges.count + 1)", nonce = Base64URL.encode(Data(UUID().uuidString.utf8))
            challenges[id] = (nonce, try thumbprint(body), false)
            return (200, ["challenge_id": id, "nonce": nonce, "expires_at": "2026-07-31T12:05:00Z"])
        }
        guard let key, key.count >= 16 else { return error(400, "idempotency_key_required") }
        if let stored = replays[key] { return (200, try JSONSerialization.jsonObject(with: stored) as! [String: Any]) }
        if let failure = failNext {
            failNext = nil
            return error(failure.status, failure.code, retryable: failure.retryable)
        }
        mutationsReceived += 1
        let (status, object) = try mutate(path, body)
        if status == 200 { replays[key] = try json(object) }
        afterMutation?()
        if loseNextResponse {
            loseNextResponse = false
            throw URLError(.networkConnectionLost)
        }
        return (status, object)
    }

    private func mutate(_ path: String, _ body: [String: Any]) throws -> (Int, [String: Any]) {
        let parts = path.split(separator: "/").map(String.init)
        let trial = parts.count >= 2 && parts[1] == "trials"
        let challenge = body["challenge"] as! [String: Any]
        let id = challenge["id"] as! String
        guard var stored = challenges[id], !stored.used, stored.nonce == challenge["nonce"] as? String,
              stored.thumbprint == (try thumbprint(body)) else { return error(401, "invalid_challenge") }
        let message: String
        if trial {
            let subject = parts.count == 4 ? parts[2] : "--"
            message = "rtfm-device-challenge-v2:\(id):\(stored.nonce):\(subject == "--" ? "trial_start" : "trial_refresh"):\(subject)"
        } else {
            message = "rtfm-device-challenge-v1:\(id):\(stored.nonce)"
        }
        let device = body["device_public_key"] as! [String: Any]
        let key = try PublicJWK(x: device["x"] as! String, y: device["y"] as! String)
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Base64URL.decode(challenge["signature"] as! String)!)
        guard key.signingKey.isValidSignature(signature, for: Data(message.utf8)) else { return error(401, "invalid_challenge_proof") }
        stored.used = true
        challenges[id] = stored
        let device_ = overrideThumbprint ?? key.thumbprint
        switch (trial, parts.last!) {
        case (false, "activations"):
            guard body["product_key"] as? String == "SYNTH-GOOD-KEY" else { return error(403, "invalid_product_key") }
            seatsUsed += 1
            let activation = "act_\(seatsUsed)"
            credentials[activation] = "cred-\(activation)"
            return (200, ["activation_id": activation, "refresh_credential": credentials[activation]!, "lease": try paidLease(activation, device_)])
        case (false, "leases"):
            guard credentials[parts[2]] == body["refresh_credential"] as? String else { return error(401, "invalid_activation_credentials") }
            return (200, ["activation_id": parts[2], "lease": try paidLease(parts[2], device_)])
        case (false, "deactivate"):
            guard credentials.removeValue(forKey: parts[2]) != nil else { return error(401, "invalid_activation_credentials") }
            seatsUsed -= 1
            return (200, ["activation_id": parts[2], "status": "deactivated", "seat_released": true])
        default:
            return (200, ["trial_id": "trl_1", "refresh_credential": "trial-cred", "lease": try trialLease(device_)])
        }
    }

    func manifest() throws -> String {
        let keys = leaseSigners.sorted { $0.key < $1.key }.map { ["kid": $0.key, "status": "active", "jwk": $0.value.jwkObject] as [String: Any] }
        return try root.sign(kid: "synthetic-root-v1", type: "rtfm.product-verification-key-manifest.v1+jws", payload: [
            "schema": "rtfm.product-verification-key-manifest.v1", "issuer": "https://synthetic-license.invalid",
            "environment": "synthetic", "product_id": "synthetic-audio", "generated_at": manifestGeneratedAt, "keys": keys,
        ])
    }

    private func claims(_ device: String) -> [String: Any] {
        sequence += 1
        return ["kid": activeKid, "iss": "https://synthetic-license.invalid", "tenant_id": "tenant_synthetic_publisher",
                "product_id": "synthetic-audio", "release_family_id": "synthetic-audio-1", "device_thumbprint": device,
                "iat": now, "nbf": now, "refresh_after": now + 75 * 86400, "exp": now + 90 * 86400, "grace_until": now + 104 * 86400,
                "sequence": sequence, "entitlements": [["code": "activation.limit", "value": 2]]]
    }

    private func paidLease(_ activation: String, _ device: String) throws -> String {
        var payload = claims(device)
        payload.merge(["schema": "rtfm.license-lease.v1", "license_id": "lic_1", "activation_id": activation, "revocation_epoch": 0]) { $1 }
        if let term { payload["term"] = term }
        return try leaseSigners[activeKid]!.sign(kid: activeKid, type: "rtfm.license-lease.v1+jws", payload: payload)
    }

    private func trialLease(_ device: String) throws -> String {
        var payload = claims(device)
        payload.merge(["schema": "rtfm.trial-lease.v1", "lease_kind": "trial", "trial_id": "trl_1", "trial_revision": 1,
                       "trial_ends_at": "2026-12-31T00:00:00.000Z", "refresh_after": now + 20 * 3600,
                       "exp": now + 24 * 3600, "grace_until": now + 36 * 3600]) { $1 }
        return try leaseSigners[activeKid]!.sign(kid: activeKid, type: "rtfm.trial-lease.v1+jws", payload: payload)
    }

    private func thumbprint(_ body: [String: Any]) throws -> String {
        let device = body["device_public_key"] as! [String: Any]
        return try PublicJWK(x: device["x"] as! String, y: device["y"] as! String).thumbprint
    }

    private func error(_ status: Int, _ code: String, retryable: Bool = false) -> (Int, [String: Any]) {
        (status, ["error": ["code": code, "message": "Synthetic \(code).", "request_id": "req_synthetic", "retryable": retryable]])
    }
}
