import Foundation

/// Builds requests for the public licensing API and classifies its responses.
struct LicensingAPI {
    let integration: AppIntegration
    let transport: HTTPTransport
    let appVersion: String

    /// The `client` metadata sent with challenges and trial requests; trial requests must repeat it exactly.
    var clientMetadata: [String: Any] {
        ["app_version": appVersion, "platform": "macos", "protocol_version": "2026-08-01"]
    }

    func verificationManifestJWS() async throws -> String {
        let object = try await send("GET", "/v1/products/\(integration.productCode)/verification-keys", body: nil)
        guard let jws = object["signature"] as? String else { throw LicensingError.service(code: "invalid_response") }
        return jws
    }

    /// `purpose` and `subjectID` are set for trial challenges (protocol v2), and absent for paid ones.
    func challenge(identity: InstallationIdentity, purpose: String? = nil, subjectID: String? = nil) async throws -> (id: String, nonce: String) {
        var body: [String: Any] = [
            "product_id": integration.productCode, "release_family_id": integration.productVersionCode,
            "device_public_key": devicePublicKey(identity), "client": clientMetadata,
        ]
        if let purpose {
            body["challenge_protocol_version"] = "v2"
            body["purpose"] = purpose
            if let subjectID { body["subject_id"] = subjectID }
        }
        let object = try await send("POST", "/v1/device-challenges", body: try encode(body))
        guard let id = object["challenge_id"] as? String, let nonce = object["nonce"] as? String else {
            throw LicensingError.service(code: "invalid_response")
        }
        return (id, nonce)
    }

    func devicePublicKey(_ identity: InstallationIdentity) -> [String: Any] {
        ["kty": "EC", "crv": "P-256", "x": identity.publicKey.x, "y": identity.publicKey.y]
    }

    func encode(_ body: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Sends a request and returns the JSON object of a 2xx response, or throws a classified `LicensingError`.
    func send(_ method: String, _ path: String, body: Data?, idempotencyKey: String? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: integration.apiBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let idempotencyKey { request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key") }
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw LicensingError.network
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200 ..< 300).contains(response.statusCode) {
            guard let object else { throw LicensingError.service(code: "invalid_response") }
            return object
        }
        let error = object?["error"] as? [String: Any]
        let code = error?["code"] as? String ?? "http_\(response.statusCode)"
        if response.statusCode >= 500 || response.statusCode == 429 || error?["retryable"] as? Bool == true {
            throw LicensingError.service(code: code)
        }
        throw LicensingError.refused(code: code, message: error?["message"] as? String ?? "The licensing service refused the request.")
    }

    static func newIdempotencyKey() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode(Data((0 ..< 32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }))
    }
}
