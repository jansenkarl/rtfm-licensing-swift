import Foundation

/// Why an online licensing operation did not complete.
public enum LicensingError: Error, Equatable, Sendable {
    /// The licensing service could not be reached. Offline use continues within signed grace.
    case network
    /// The service failed or asked to retry later (`retryable`). Treated like a network failure for grace.
    case service(code: String)
    /// The service refused the request for good, for example `activation_seat_limit_reached`,
    /// `license_revoked`, `license_term_ended` or `invalid_product_key`. `message` is safe to show.
    case refused(code: String, message: String)
    /// A response or stored lease did not verify.
    case verification(VerificationError)
    /// The license state could not be saved or read.
    case storage(String)
    /// The operation needs an activation (or a trial) this installation does not have.
    case notActivated
    case noTrial

    /// Network and service failures are the only ones that allow grace after a lease expires.
    public var allowsGrace: Bool {
        switch self {
        case .network, .service: true
        default: false
        }
    }
}
