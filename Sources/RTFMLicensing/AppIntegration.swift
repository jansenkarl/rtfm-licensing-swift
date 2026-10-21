import Foundation

/// The public App integration file a publisher downloads from the License Manager for one Product Version
/// (`rtfm.app-integration.v1`). It holds no secrets. The pinned root key comes only from this file, which ships
/// inside the app, never from a downloaded manifest.
public struct AppIntegration: Equatable, Sendable {
    public let environment: String
    /// The licensing API base URL, which is also the issuer named in manifests and leases.
    public let apiBaseURL: URL
    public let productCode: String
    public let productVersionCode: String
    public let rootKeyID: String
    public let rootPublicKey: PublicJWK
    /// Checked against each lease when present. Older App integration files do not include it.
    public let tenantID: String?

    public var issuer: String { apiBaseURL.absoluteString }

    public init(json data: Data) throws {
        guard let object = (try? JSONValue.parse(data))?.objectValue else {
            throw VerificationError.malformed("App integration file is not a JSON object")
        }
        guard object["schema"] == .string("rtfm.app-integration.v1") else {
            throw VerificationError.malformed("App integration schema is not rtfm.app-integration.v1")
        }
        func text(_ key: String) throws -> String {
            guard let value = object[key]?.stringValue, !value.isEmpty else {
                throw VerificationError.malformed("App integration file is missing \(key)")
            }
            return value
        }
        let base = try text("apiBaseUrl")
        guard let url = URL(string: base), url.scheme == "https", url.host != nil, url.path.isEmpty,
              url.query == nil, url.fragment == nil else {
            throw VerificationError.malformed("apiBaseUrl must be an https origin")
        }
        environment = try text("environment")
        apiBaseURL = url
        productCode = try text("productCode")
        productVersionCode = try text("productVersionCode")
        rootKeyID = try text("rootKeyId")
        rootPublicKey = try PublicJWK(json: object["rootPublicJwk"])
        if let tenant = object["tenantId"] {
            guard let value = tenant.stringValue, !value.isEmpty else {
                throw VerificationError.malformed("tenantId must be a non-empty string")
            }
            tenantID = value
        } else {
            tenantID = nil
        }
    }
}
