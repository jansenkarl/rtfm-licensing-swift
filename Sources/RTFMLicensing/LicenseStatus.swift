import Foundation

/// What the app should do now: run licensed, run in trial, or ask for a key.
public enum LicenseStatus: Equatable, Sendable {
    /// Not yet checked (before `RTFMLicense.start()` finishes).
    case checking
    case licensed(LicenseInfo)
    case trial(TrialInfo)
    case notLicensed(NotLicensedReason)

    public var allowsUse: Bool {
        switch self {
        case .licensed, .trial: true
        default: false
        }
    }
}

public struct LicenseInfo: Equatable, Sendable {
    public let licenseID: String
    public let entitlements: [Entitlement]
    /// For a fixed-term or subscription key: show "Renews <endsAt>" or "Ends <endsAt>".
    public let term: Lease.Term?
    /// The lease expired and the licensing service could not be reached; use continues until `graceUntil`.
    public let inGrace: Bool
    public let graceUntil: Date

    public func entitlement(_ code: String) -> Entitlement.Value? { entitlements.first { $0.code == code }?.value }
}

public struct TrialInfo: Equatable, Sendable {
    public let endsAt: Date
    public let inGrace: Bool
    public let entitlements: [Entitlement]
}

public enum NotLicensedReason: Equatable, Sendable {
    /// No key has been entered on this Mac (and no trial started).
    case notActivated
    /// The lease expired and could not be renewed; going online renews it.
    case expired
    /// The fixed term or subscription has ended.
    case termEnded
    case trialEnded
    /// The key was revoked, deactivated elsewhere, or otherwise refused by the licensing service.
    case refused(code: String)
    /// The Mac's clock is earlier than a time already seen; correct the date and time.
    case clockRolledBack
    /// The stored license did not verify; activate again.
    case invalidStoredLicense
}

/// Turns stored state into a status, offline: verifies the stored leases again and applies their timing.
enum StatusEvaluator {
    /// A clock may move back a little (time sync); only a larger step back is treated as a rollback.
    static let clockTolerance: Int64 = 300

    static func evaluate(_ state: LicenseState, integration: AppIntegration, now: Int64, network: AccessTiming.Network) -> LicenseStatus {
        guard let manifestJWS = state.manifest, let manifest = try? VerificationManifest(jws: manifestJWS, integration: integration),
              let identity = try? InstallationIdentity(rawRepresentation: state.installationKey) else {
            return state.paidLease == nil && state.trialLease == nil ? .notLicensed(.notActivated) : .notLicensed(.invalidStoredLicense)
        }
        // The stored leases were accepted at or above today's high-water marks, so they are checked from zero here.
        let expectations = LeaseExpectations(integration: integration, deviceThumbprint: identity.thumbprint, highWater: HighWater())
        let observed = state.highWater.observedTime - clockTolerance
        var paidReason: NotLicensedReason?
        if let jws = state.paidLease {
            guard let lease = try? LeaseVerifier.verify(jws, as: .paid, manifest: manifest, expectations: expectations),
                  case let .paid(licenseID, _, _) = lease.kind else { return .notLicensed(.invalidStoredLicense) }
            if let term = lease.term, Double(now) >= term.accessEndsAt.timeIntervalSince1970 {
                paidReason = .termEnded
            } else {
                switch AccessTiming.decide(lease, now: now, observedTime: observed, network: network) {
                case .valid, .grace:
                    return .licensed(LicenseInfo(licenseID: licenseID, entitlements: lease.entitlements, term: lease.term,
                                                 inGrace: now > lease.expiresAt, graceUntil: Date(timeIntervalSince1970: TimeInterval(lease.graceUntil))))
                case .clockRolledBack, .notYetValid: return .notLicensed(.clockRolledBack)
                default: paidReason = .expired
                }
            }
        }
        if let jws = state.trialLease {
            guard let lease = try? LeaseVerifier.verify(jws, as: .trial, manifest: manifest, expectations: expectations),
                  case let .trial(_, endsAt, _) = lease.kind else { return paidReason.map { .notLicensed($0) } ?? .notLicensed(.invalidStoredLicense) }
            switch AccessTiming.decide(lease, now: now, observedTime: observed, network: network) {
            case .valid, .grace: return .trial(TrialInfo(endsAt: endsAt, inGrace: now > lease.expiresAt, entitlements: lease.entitlements))
            case .clockRolledBack, .notYetValid: return .notLicensed(paidReason ?? .clockRolledBack)
            case .trialEnded: return .notLicensed(paidReason ?? .trialEnded)
            default: return .notLicensed(paidReason ?? .expired)
            }
        }
        return .notLicensed(paidReason ?? .notActivated)
    }
}
