/// Why a manifest, lease or app integration file was not accepted. Every case fails closed.
public enum VerificationError: Error, Equatable, Sendable {
    case malformed(String)
    case untrustedSignature
    case unexpectedHeader(String)
    case wrongScope(String)
    case unknownKey(String)
    case inactiveKey(String)
    case staleState(String)
    case invalidTiming(String)
}
