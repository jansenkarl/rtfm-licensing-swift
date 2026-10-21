import Foundation

/// The signing-key rotation rule (RTFM licensing repository, `docs/MANAGED_NATIVE_SDK_GATE2_HANDOFF.md`):
/// trust only active keys in the newest root-signed manifest held; on an unlisted `kid`, fetch the manifest once
/// more (at most once per `kid` per hour); never replace the held manifest with an older one.
public enum KeyRotation {
    public static let refetchInterval: TimeInterval = 3600

    public struct Outcome: Sendable {
        /// The manifest to keep (and store) afterwards.
        public let manifest: VerificationManifest
        /// The active key for the lease's `kid`, or nil when the lease must not be accepted.
        public let key: ManifestKey?
        public let fetched: Bool
    }

    /// `fetch` returns a manifest already verified against the pinned root, or throws (network failure or a
    /// manifest that did not verify).
    public static func resolve(kid: String, held: VerificationManifest, lastRefetchForKid: Date?, now: Date,
                               fetch: () async throws -> VerificationManifest) async -> Outcome {
        if let listed = held.listedKey(kid) {
            return Outcome(manifest: held, key: listed.status == "active" ? listed : nil, fetched: false)
        }
        if let last = lastRefetchForKid, now.timeIntervalSince(last) < refetchInterval {
            return Outcome(manifest: held, key: nil, fetched: false)
        }
        guard let fresh = try? await fetch(), fresh.generatedAt >= held.generatedAt else {
            return Outcome(manifest: held, key: nil, fetched: true)
        }
        let listed = fresh.listedKey(kid)
        return Outcome(manifest: fresh, key: listed?.status == "active" ? listed : nil, fetched: true)
    }
}
