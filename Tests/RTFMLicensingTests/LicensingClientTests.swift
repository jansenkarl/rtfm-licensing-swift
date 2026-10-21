import Foundation
import XCTest
@testable import RTFMLicensing

final class LicensingClientTests: XCTestCase {
    struct DiskFull: Error {}
    var server: FakeLicensingServer!
    var store: MemoryLicenseStore!
    var client: LicensingClient!

    override func setUp() {
        server = FakeLicensingServer()
        store = MemoryLicenseStore()
        let now = Date(timeIntervalSince1970: TimeInterval(server.now))
        client = LicensingClient(integration: server.integration, store: store, appVersion: "1.0", transport: server, now: { now })
    }

    func testActivateRefreshAndDeactivate() async throws {
        let lease = try await client.activate(productKey: " SYNTH-GOOD-KEY\n")
        XCTAssertEqual(lease.sequence, 1)
        XCTAssertEqual(lease.entitlements, [Entitlement(code: "activation.limit", value: .integer(2))])
        var state = try XCTUnwrap(store.load())
        XCTAssertEqual(state.activation?.activationID, "act_1")
        XCTAssertEqual(state.paidLease, lease.jws)
        XCTAssertNotNil(state.manifest)
        XCTAssertNil(state.pendingOperation)
        XCTAssertEqual(state.highWater, HighWater(sequence: 1, observedTime: server.now, activationID: "act_1", licenseID: "lic_1"))

        let refreshed = try await client.refresh()
        XCTAssertEqual(refreshed.sequence, 2)
        XCTAssertEqual(try store.load()?.highWater.sequence, 2)

        try await client.deactivate()
        state = try XCTUnwrap(store.load())
        XCTAssertNil(state.activation)
        XCTAssertNil(state.paidLease)
        XCTAssertEqual(server.seatsUsed, 0)
        XCTAssertEqual(state.highWater.sequence, 2, "high-water marks survive deactivation")
    }

    func testLostResponseIsReplayedExactlyWithoutASecondSeat() async throws {
        server.loseNextResponse = true
        await assertThrows(try await client.activate(productKey: "SYNTH-GOOD-KEY"), .network)
        let pending = try XCTUnwrap(store.load()?.pendingOperation)
        XCTAssertEqual(pending.operation, .activate)
        XCTAssertNil(try store.load()?.activation)

        try await client.completePending()
        XCTAssertEqual(server.seatsUsed, 1)
        XCTAssertEqual(server.mutationsReceived, 1, "the replay was answered from the stored response")
        XCTAssertEqual(try store.load()?.activation?.activationID, "act_1")
        XCTAssertNil(try store.load()?.pendingOperation)
    }

    func testFailedCommitAfterSuccessKeepsTheRequestForReplay() async throws {
        let store = store!
        server.afterMutation = { store.failCommits = DiskFull() }
        await assertThrows(try await client.activate(productKey: "SYNTH-GOOD-KEY"), .storage("DiskFull()"))
        server.afterMutation = nil
        store.failCommits = nil
        XCTAssertNotNil(try store.load()?.pendingOperation, "the journal written before sending is intact")

        let refreshed = try await client.refresh() // replays the activation first, then refreshes
        XCTAssertEqual(refreshed.sequence, 2)
        XCTAssertEqual(server.seatsUsed, 1)
        XCTAssertEqual(try store.load()?.highWater.sequence, 2)
    }

    func testNothingIsSentWhenTheJournalCannotBeWritten() async throws {
        _ = try await client.state()
        store.failCommits = DiskFull()
        await assertThrows(try await client.activate(productKey: "SYNTH-GOOD-KEY"), .storage("DiskFull()"))
        XCTAssertEqual(server.mutationsReceived, 0)
    }

    func testRefusalClearsThePendingRequestAndRetryableFailureKeepsIt() async throws {
        await assertThrows(try await client.activate(productKey: "SYNTH-BAD-KEY"),
                           .refused(code: "invalid_product_key", message: "Synthetic invalid_product_key."))
        XCTAssertNil(try store.load()?.pendingOperation)

        server.failNext = (503, "service_unavailable", true)
        await assertThrows(try await client.activate(productKey: "SYNTH-GOOD-KEY"), .service(code: "service_unavailable"))
        XCTAssertNotNil(try store.load()?.pendingOperation)
        XCTAssertTrue(LicensingError.service(code: "x").allowsGrace)
        XCTAssertFalse(LicensingError.refused(code: "x", message: "").allowsGrace)
    }

    func testRotatedSigningKeyIsFetchedOnce() async throws {
        _ = try await client.activate(productKey: "SYNTH-GOOD-KEY")
        server.leaseSigners["lease-2"] = TestSigner()
        server.activeKid = "lease-2"
        server.manifestGeneratedAt = "2026-08-01T12:00:00.000Z"
        let lease = try await client.refresh()
        XCTAssertEqual(lease.keyID, "lease-2")
        let state = try XCTUnwrap(store.load())
        XCTAssertNotNil(state.manifestRefetches["lease-2"])
        XCTAssertEqual(try VerificationManifest(jws: XCTUnwrap(state.manifest), integration: server.integration).keys.count, 2)
    }

    func testALeaseForAnotherInstallationIsRefused() async throws {
        server.overrideThumbprint = "sha256:someone-else"
        await assertThrows(try await client.activate(productKey: "SYNTH-GOOD-KEY"), .verification(.wrongScope("lease installation")))
        XCTAssertNil(try store.load()?.activation)
        XCTAssertNil(try store.load()?.pendingOperation, "a mis-scoped lease will not verify on replay either")
    }

    func testTrialStartAndRefresh() async throws {
        await assertThrows(try await client.refreshTrial(), .noTrial)
        let lease = try await client.startTrial()
        guard case let .trial(trialID, _, revision) = lease.kind else { return XCTFail("expected a trial lease") }
        XCTAssertEqual([trialID, "\(revision)"], ["trl_1", "1"])
        XCTAssertEqual(try store.load()?.trialRefreshCredential, "trial-cred")
        let refreshed = try await client.refreshTrial()
        XCTAssertEqual(refreshed.sequence, 2)
    }

    func testATrialAfterAPaidKeyAndASecondActivationEachStartTheirOwnSequence() async throws {
        // Regression (staging, 2026-10-21): one shared sequence mark refused a new trial's lease 1 after paid lease 3.
        _ = try await client.activate(productKey: "SYNTH-GOOD-KEY")
        _ = try await client.refresh()
        _ = try await client.refresh()
        try await client.deactivate()
        let trial = try await client.startTrial()
        XCTAssertEqual(trial.sequence, 1)
        let second = try await client.activate(productKey: "SYNTH-GOOD-KEY")
        XCTAssertEqual(second.sequence, 1, "a new activation numbers its leases from 1")
        let marks = try XCTUnwrap(store.load()?.highWater)
        XCTAssertEqual([marks.sequence, marks.trialSequence], [1, 1])
        XCTAssertEqual([marks.activationID, marks.trialID], ["act_2", "trl_1"])
    }

    func testWithinOneActivationAnOlderLeaseIsStillRefused() throws {
        let marks = HighWater(sequence: 5, activationID: "act_1")
        let state = LicenseState(installationKey: Data()).accepting(Lease(
            kind: .paid(licenseID: "lic_1", activationID: "act_1", revocationEpoch: 0), jws: "j", keyID: "k", sequence: 3,
            issuedAt: 0, notBefore: 0, refreshAfter: 1, expiresAt: 2, graceUntil: 3, entitlements: []))
        XCTAssertEqual(state.highWater.sequence, 3, "accepting sets marks; the verifier is what refuses lower ones")
        XCTAssertTrue(HighWater.applies(marks.activationID, to: "act_1"))
        XCTAssertFalse(HighWater.applies(marks.activationID, to: "act_2"))
        XCTAssertTrue(HighWater.applies(nil, to: "act_2"), "a mark without a scope applies to every lease")
    }

    private func assertThrows<T>(_ expression: @autoclosure () async throws -> T, _ expected: LicensingError,
                                 file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await expression()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? LicensingError, expected, file: file, line: line)
        }
    }
}
