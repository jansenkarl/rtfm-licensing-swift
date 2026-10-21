import CryptoKit
import Foundation

/// The installation's own P-256 key. It identifies this copy of the app to the server; no hardware identifiers
/// are collected.
public struct InstallationIdentity: Sendable {
    let privateKey: P256.Signing.PrivateKey

    public static func generate() -> InstallationIdentity {
        InstallationIdentity(privateKey: P256.Signing.PrivateKey())
    }

    public init(rawRepresentation: Data) throws {
        privateKey = try P256.Signing.PrivateKey(rawRepresentation: rawRepresentation)
    }

    init(privateKey: P256.Signing.PrivateKey) {
        self.privateKey = privateKey
    }

    public var rawRepresentation: Data { privateKey.rawRepresentation }
    public var publicKey: PublicJWK { PublicJWK(privateKey.publicKey) }
    public var thumbprint: String { publicKey.thumbprint }

    /// Signs a challenge proof message and returns the raw r||s signature, base64url-encoded.
    func sign(_ message: String) throws -> String {
        Base64URL.encode(try privateKey.signature(for: Data(message.utf8)).rawRepresentation)
    }
}
