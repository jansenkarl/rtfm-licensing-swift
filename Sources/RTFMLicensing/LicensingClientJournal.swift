import Foundation

extension LicensingClient {
    /// Writes the request down, sends it, and commits its verified result; see `send(_:state:)`.
    func perform(_ operation: LicenseState.Operation, _ path: String, body: Data, state: LicenseState) async throws -> Lease? {
        var journaled = state
        journaled.pendingOperation = .init(operation: operation, path: path, body: body, idempotencyKey: LicensingAPI.newIdempotencyKey())
        try commit(journaled)
        return try await send(journaled.pendingOperation!, state: journaled)
    }

    /// Replays a request left pending by a lost response or a failed commit, before anything new is sent.
    public func completePending() async throws {
        let state = try state()
        guard let pending = state.pendingOperation else { return }
        _ = try await send(pending, state: state)
    }

    /// Sends a journaled request. A network or retryable service failure keeps it pending for an exact replay; a
    /// refusal clears it. A success is verified, then committed with the pending request cleared.
    private func send(_ pending: LicenseState.PendingOperation, state: LicenseState) async throws -> Lease? {
        let response: [String: Any]
        do {
            response = try await api.send("POST", pending.path, body: pending.body, idempotencyKey: pending.idempotencyKey)
        } catch let error as LicensingError {
            if case .refused = error {
                var cleared = state
                cleared.pendingOperation = nil
                try commit(cleared)
            }
            throw error
        }
        do {
            return try await commitResult(response, of: pending.operation, state: state)
        } catch let LicensingError.verification(error) {
            // A lease naming a key not yet listed may verify after the manifest is fetched again later, so the
            // request stays pending for replay; any other verification failure will not change on replay.
            if case .unknownKey = error {} else {
                var cleared = state
                cleared.pendingOperation = nil
                try commit(cleared)
            }
            throw LicensingError.verification(error)
        }
    }

    private func commitResult(_ response: [String: Any], of operation: LicenseState.Operation, state: LicenseState) async throws -> Lease? {
        var next = state
        next.pendingOperation = nil
        var lease: Lease?
        switch operation {
        case .activate:
            guard let id = response["activation_id"] as? String, let credential = response["refresh_credential"] as? String else {
                throw LicensingError.service(code: "invalid_response")
            }
            next.activation = .init(activationID: id, refreshCredential: credential)
            lease = try await verify(response["lease"], as: .paid, state: &next)
        case .refresh:
            lease = try await verify(response["lease"], as: .paid, state: &next)
        case .deactivate:
            next.activation = nil
            next.paidLease = nil
        case .startTrial, .refreshTrial:
            guard let id = response["trial_id"] as? String, let credential = response["refresh_credential"] as? String else {
                throw LicensingError.service(code: "invalid_response")
            }
            next.trialID = id
            next.trialRefreshCredential = credential
            lease = try await verify(response["lease"], as: .trial, state: &next)
        }
        try commit(next.observing(unixNow))
        return lease
    }

    /// Verifies a lease from a response against the held manifest (fetching it, or once more for a new `kid`),
    /// and adds it and its high-water marks to `state`.
    func verify(_ value: Any?, as kind: LeaseVerifier.Expected, state: inout LicenseState) async throws -> Lease {
        guard let jws = value as? String else { throw LicensingError.service(code: "invalid_response") }
        let identity = try identity(state)
        let manifest = try await manifestFor(jws, state: &state)
        do {
            let lease = try LeaseVerifier.verify(jws, as: kind, manifest: manifest, expectations: LeaseExpectations(
                integration: integration, deviceThumbprint: identity.thumbprint, highWater: state.highWater))
            state = state.accepting(lease)
            return lease
        } catch let error as VerificationError {
            throw LicensingError.verification(error)
        }
    }

    /// The manifest that should list the lease's key, following the key-rotation rule.
    func manifestFor(_ jws: String, state: inout LicenseState) async throws -> VerificationManifest {
        let kid: String
        do { kid = try CompactJWS.unverifiedKeyID(jws) } catch let error as VerificationError {
            throw LicensingError.verification(error)
        }
        let held: VerificationManifest
        if let stored = state.manifest, let verified = try? VerificationManifest(jws: stored, integration: integration) {
            held = verified
        } else {
            held = try await fetchManifest()
            state.manifest = held.jws
            return held
        }
        let outcome = await KeyRotation.resolve(kid: kid, held: held, lastRefetchForKid: state.manifestRefetches[kid], now: now()) {
            try await self.fetchManifest()
        }
        if outcome.fetched { state.manifestRefetches[kid] = now() }
        state.manifest = outcome.manifest.jws
        return outcome.manifest
    }

    func fetchManifest() async throws -> VerificationManifest {
        let jws = try await api.verificationManifestJWS()
        do { return try VerificationManifest(jws: jws, integration: integration) } catch let error as VerificationError {
            throw LicensingError.verification(error)
        }
    }
}
