import Foundation

/// A lease whose signature, scope and high-water marks have been checked.
public struct Lease: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case paid(licenseID: String, activationID: String, revocationEpoch: Int64)
        case trial(trialID: String, endsAt: Date, revision: Int64)
    }

    public let kind: Kind
    public let jws: String
    public let keyID: String
    public let sequence: Int64
    public let issuedAt: Int64
    public let notBefore: Int64
    /// Unix seconds: refresh quietly after this; it is never a blocking point.
    public let refreshAfter: Int64
    /// Unix seconds: the lease is valid until this.
    public let expiresAt: Int64
    /// Unix seconds: after `expiresAt`, a network or service failure still allows use until this.
    public let graceUntil: Int64
    public let entitlements: [Entitlement]
}

/// What a lease must match: the app's own Product Version and installation, and what the app has already seen.
public struct LeaseExpectations: Equatable, Sendable {
    public var integration: AppIntegration
    public var deviceThumbprint: String
    public var highWater: HighWater

    public init(integration: AppIntegration, deviceThumbprint: String, highWater: HighWater) {
        self.integration = integration
        self.deviceThumbprint = deviceThumbprint
        self.highWater = highWater
    }
}

/// The highest values already accepted; a lease below them is a replay or a rollback and is refused.
public struct HighWater: Codable, Equatable, Sendable {
    public var sequence: Int64 = 0
    public var revocationEpoch: Int64 = 0
    public var trialRevision: Int64 = 0
    /// The latest wall-clock time the app has observed, in Unix seconds.
    public var observedTime: Int64 = 0

    public init(sequence: Int64 = 0, revocationEpoch: Int64 = 0, trialRevision: Int64 = 0, observedTime: Int64 = 0) {
        self.sequence = sequence
        self.revocationEpoch = revocationEpoch
        self.trialRevision = trialRevision
        self.observedTime = observedTime
    }
}
