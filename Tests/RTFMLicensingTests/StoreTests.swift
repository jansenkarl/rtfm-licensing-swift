import CryptoKit
import Foundation
import Security
import XCTest
@testable import RTFMLicensing

final class StoreTests: XCTestCase {
    struct DiskFull: Error {}

    private func sampleState() -> LicenseState {
        var state = LicenseState(installationKey: InstallationIdentity.generate().rawRepresentation)
        state.activation = .init(activationID: "act_synthetic", refreshCredential: "synthetic-credential")
        state.paidLease = "a.b.c"
        state.highWater = HighWater(sequence: 4, revocationEpoch: 1, observedTime: 1_785_499_200)
        state.manifestRefetches = ["kid-2": Date(timeIntervalSince1970: 1_785_499_200)]
        state.pendingOperation = .init(operation: .activate, path: "/v1/activations", body: Data("{}".utf8), idempotencyKey: "idem-1")
        return state
    }

    func testMemoryStoreRoundTripAndFailedCommitKeepsThePreviousState() throws {
        let store = MemoryLicenseStore()
        XCTAssertNil(try store.load())
        let first = sampleState()
        try store.commit(first)
        XCTAssertEqual(try store.load(), first)
        var second = first
        second.highWater.sequence = 5
        store.failCommits = DiskFull()
        XCTAssertThrowsError(try store.commit(second))
        XCTAssertEqual(try store.load(), first, "a failed commit leaves the earlier state whole")
        store.failCommits = nil
        try store.commit(second)
        XCTAssertEqual(try store.load()?.highWater.sequence, 5)
        try store.erase()
        XCTAssertNil(try store.load())
    }

    func testUnreadableStateIsNotTrusted() {
        XCTAssertThrowsError(try LicenseStateCoding.decode(Data("not json".utf8))) {
            XCTAssertEqual($0 as? StoreError, .unreadable)
        }
    }

    func testAcceptingALeaseRaisesButNeverLowersHighWater() throws {
        var state = sampleState()
        state.highWater = HighWater(sequence: 9, revocationEpoch: 3, trialRevision: 2, observedTime: 100)
        let lease = Lease(kind: .paid(licenseID: "lic", activationID: "act", revocationEpoch: 5), jws: "new.lease.jws", keyID: "k",
                          sequence: 7, issuedAt: 0, notBefore: 0, refreshAfter: 1, expiresAt: 2, graceUntil: 3, entitlements: [])
        let next = state.accepting(lease).observing(50)
        XCTAssertEqual(next.paidLease, "new.lease.jws")
        XCTAssertEqual(next.highWater, HighWater(sequence: 9, revocationEpoch: 5, trialRevision: 2, observedTime: 100))
    }

    func testInstallationIdentitySignsChallengeProofs() throws {
        let identity = InstallationIdentity.generate()
        let restored = try InstallationIdentity(rawRepresentation: identity.rawRepresentation)
        XCTAssertEqual(restored.thumbprint, identity.thumbprint)
        let message = "rtfm-device-challenge-v1:chg_synthetic:nonce"
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Base64URL.decode(identity.sign(message))))
        XCTAssertTrue(identity.publicKey.signingKey.isValidSignature(signature, for: Data(message.utf8)))
    }

    /// Uses the real login Keychain, so it runs only when asked: `RTFM_KEYCHAIN_TESTS=1 swift test`.
    func testKeychainStore() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["RTFM_KEYCHAIN_TESTS"] == "1", "set RTFM_KEYCHAIN_TESTS=1")
        let store = KeychainLicenseStore(service: "com.rtfmdesign.licensing.tests.\(UUID().uuidString)")
        defer { try? store.erase() }
        XCTAssertNil(try store.load())
        let state = sampleState()
        try store.commit(state)
        XCTAssertEqual(try store.load(), state)
        var next = state
        next.highWater.sequence = 10
        try store.commit(next)
        XCTAssertEqual(try store.load(), next)
        // An updated build that may not delete the item leaves the one-byte marker, which reads as nothing stored.
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: store.service, kSecAttrAccount as String: store.account]
        XCTAssertEqual(SecItemUpdate(query as CFDictionary, [kSecValueData as String: KeychainLicenseStore.erasedMarker] as CFDictionary), errSecSuccess)
        XCTAssertNil(try store.load())
        try store.erase()
        XCTAssertNil(try store.load())
    }
}
