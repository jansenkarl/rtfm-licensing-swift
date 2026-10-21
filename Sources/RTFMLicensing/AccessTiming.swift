import Foundation

/// Whether a verified lease grants access at a given time.
public enum AccessTiming {
    /// What happened when the app last tried to reach the licensing service.
    public enum Network: Equatable, Sendable {
        /// No refresh was attempted, or none was needed.
        case notChecked
        /// The service answered (with or without a new lease).
        case available
        /// A network or service failure: the only case that allows grace after expiry.
        case unavailable
    }

    public enum Decision: Equatable, Sendable {
        case valid
        /// Expired, but within signed grace because the service could not be reached.
        case grace
        case notYetValid
        /// The clock is earlier than a time the app has already observed.
        case clockRolledBack
        case expired
        case trialEnded
    }

    public static func decide(_ lease: Lease, now: Int64, observedTime: Int64, network: Network) -> Decision {
        if lease.issuedAt > now || lease.notBefore > now { return .notYetValid }
        if observedTime > now { return .clockRolledBack }
        if case let .trial(_, endsAt, _) = lease.kind, Double(now) >= endsAt.timeIntervalSince1970 { return .trialEnded }
        if now <= lease.expiresAt { return .valid }
        if now <= lease.graceUntil && network == .unavailable { return .grace }
        return .expired
    }
}
