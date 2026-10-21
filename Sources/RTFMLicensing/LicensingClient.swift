import Foundation

/// The online side of licensing: challenges, activation, refresh, deactivation and trials. Each mutation is
/// written to the store before it is sent and replayed exactly after a lost response, so a seat is never spent
/// twice; its result and the raised high-water marks are committed together.
public actor LicensingClient {
    let api: LicensingAPI
    let store: LicenseStore
    let now: @Sendable () -> Date

    public init(integration: AppIntegration, store: LicenseStore, appVersion: String,
                transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        api = LicensingAPI(integration: integration, transport: transport, appVersion: appVersion)
        self.store = store
        self.now = now
    }

    var integration: AppIntegration { api.integration }
    var unixNow: Int64 { Int64(now().timeIntervalSince1970) }

    // MARK: State

    /// The stored state, creating the installation identity on first use.
    public func state() throws -> LicenseState {
        let stored: LicenseState?
        do { stored = try store.load() } catch { throw LicensingError.storage("\(error)") }
        if let stored { return stored }
        let fresh = LicenseState(installationKey: InstallationIdentity.generate().rawRepresentation)
        try commit(fresh)
        return fresh
    }

    func commit(_ state: LicenseState) throws {
        do { try store.commit(state) } catch { throw LicensingError.storage("\(error)") }
    }

    func identity(_ state: LicenseState) throws -> InstallationIdentity {
        do { return try InstallationIdentity(rawRepresentation: state.installationKey) } catch {
            throw LicensingError.storage("installation key unreadable")
        }
    }

    // MARK: Paid operations

    public func activate(productKey: String, deviceLabel: String? = nil) async throws -> Lease {
        try await completePending()
        let state = try state()
        let identity = try identity(state)
        let challenge = try await api.challenge(identity: identity)
        var body: [String: Any] = [
            "product_id": integration.productCode, "release_family_id": integration.productVersionCode,
            "product_key": productKey.trimmingCharacters(in: .whitespacesAndNewlines),
            "device_public_key": api.devicePublicKey(identity), "challenge": try paidProof(challenge, identity),
        ]
        if let deviceLabel, !deviceLabel.isEmpty { body["device_label"] = deviceLabel }
        return try await perform(.activate, "/v1/activations", body: try api.encode(body), state: state)!
    }

    public func refresh() async throws -> Lease {
        try await completePending()
        let state = try state()
        guard let activation = state.activation else { throw LicensingError.notActivated }
        let body = try await credentialBody(activation.refreshCredential, state: state)
        return try await perform(.refresh, "/v1/activations/\(activation.activationID)/leases", body: body, state: state)!
    }

    /// Releases this installation's seat so the key can be used on another Mac.
    public func deactivate() async throws {
        try await completePending()
        let state = try state()
        guard let activation = state.activation else { throw LicensingError.notActivated }
        let body = try await credentialBody(activation.refreshCredential, state: state)
        _ = try await perform(.deactivate, "/v1/activations/\(activation.activationID)/deactivate", body: body, state: state)
    }

    private func credentialBody(_ credential: String, state: LicenseState) async throws -> Data {
        let identity = try identity(state)
        let challenge = try await api.challenge(identity: identity)
        return try api.encode(["refresh_credential": credential, "device_public_key": api.devicePublicKey(identity),
                               "challenge": try paidProof(challenge, identity)])
    }

    private func paidProof(_ challenge: (id: String, nonce: String), _ identity: InstallationIdentity) throws -> [String: Any] {
        ["id": challenge.id, "nonce": challenge.nonce, "proof_version": "rtfm-device-challenge-v1",
         "signature": try identity.sign("rtfm-device-challenge-v1:\(challenge.id):\(challenge.nonce)")]
    }

    // MARK: Trials

    public func startTrial() async throws -> Lease {
        try await completePending()
        let state = try state()
        let body = try await trialBody(purpose: "trial_start", subjectID: nil, extra: [
            "product_id": integration.productCode, "release_family_id": integration.productVersionCode,
        ], state: state)
        return try await perform(.startTrial, "/v1/trials", body: body, state: state)!
    }

    public func refreshTrial() async throws -> Lease {
        try await completePending()
        let state = try state()
        guard let trialID = state.trialID, let credential = state.trialRefreshCredential else { throw LicensingError.noTrial }
        let body = try await trialBody(purpose: "trial_refresh", subjectID: trialID, extra: ["refresh_credential": credential], state: state)
        return try await perform(.refreshTrial, "/v1/trials/\(trialID)/leases", body: body, state: state)!
    }

    private func trialBody(purpose: String, subjectID: String?, extra: [String: Any], state: LicenseState) async throws -> Data {
        let identity = try identity(state)
        let challenge = try await api.challenge(identity: identity, purpose: purpose, subjectID: subjectID)
        let message = "rtfm-device-challenge-v2:\(challenge.id):\(challenge.nonce):\(purpose):\(subjectID ?? "--")"
        var body = extra
        body["device_public_key"] = api.devicePublicKey(identity)
        body["client"] = api.clientMetadata
        body["challenge"] = ["id": challenge.id, "nonce": challenge.nonce, "signature": try identity.sign(message)]
        return try api.encode(body)
    }
}
