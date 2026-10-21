import Foundation
import XCTest
@testable import RTFMLicensing

@MainActor
final class RTFMLicenseTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var seconds: Int64
        init(_ seconds: Int64) { self.seconds = seconds }
        var date: Date { lock.withLock { Date(timeIntervalSince1970: TimeInterval(seconds)) } }
    }

    var server: FakeLicensingServer!
    var store: MemoryLicenseStore!
    var clock: Clock!
    var license: RTFMLicense!
    let day: Int64 = 86400

    override func setUp() async throws {
        server = FakeLicensingServer()
        store = MemoryLicenseStore()
        clock = Clock(server.now)
        let clock = clock!
        license = RTFMLicense(integration: server.integration, store: store, appVersion: "1.0", transport: server, now: { clock.date })
    }

    private func at(_ seconds: Int64) {
        clock.seconds = seconds
        server.now = seconds
    }

    func testNothingStoredMeansNotActivated() async {
        XCTAssertEqual(license.status, .checking)
        await license.start()
        XCTAssertEqual(license.status, .notLicensed(.notActivated))
        XCTAssertFalse(license.status.allowsUse)
    }

    func testActivatedKeyWorksOfflineThenInGraceThenExpires() async throws {
        try await license.activate(productKey: "SYNTH-GOOD-KEY")
        guard case let .licensed(info) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertEqual(info.entitlement("activation.limit"), .integer(2))
        XCTAssertFalse(info.inGrace)
        XCTAssertNil(info.term)

        server.offline = true
        clock.seconds = server.now + 80 * day // past refresh_after: tries quietly, fails, still licensed
        await license.start()
        XCTAssertTrue(license.status.allowsUse)
        clock.seconds = server.now + 95 * day // past exp, within grace, offline
        await license.start()
        guard case let .licensed(grace) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertTrue(grace.inGrace)
        clock.seconds = server.now + 105 * day // past grace
        await license.start()
        XCTAssertEqual(license.status, .notLicensed(.expired))

        server.offline = false // back online: the lease renews
        at(server.now + 105 * day)
        await license.start()
        guard case let .licensed(renewed) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertFalse(renewed.inGrace)
    }

    func testAKeyRefusedOnRenewalStopsAndIsForgotten() async throws {
        try await license.activate(productKey: "SYNTH-GOOD-KEY")
        at(server.now + 80 * day)
        server.failNext = (401, "invalid_activation_credentials", false)
        await license.start()
        XCTAssertEqual(license.status, .notLicensed(.refused(code: "invalid_activation_credentials")))
        XCTAssertNil(try store.load()?.paidLease)
        await license.start()
        XCTAssertEqual(license.status, .notLicensed(.notActivated))
    }

    func testSubscriptionTermIsShownAndEnds() async throws {
        server.term = ["type": "subscription", "ends_at": "2026-08-30T00:00:00.000Z", "access_ends_at": "2026-09-02T00:00:00.000Z"]
        try await license.activate(productKey: "SYNTH-GOOD-KEY")
        guard case let .licensed(info) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertEqual(info.term?.kind, .subscription)
        XCTAssertEqual(info.term?.endsAt, Timestamp.parse("2026-08-30T00:00:00.000Z"))
        server.offline = true
        clock.seconds = Int64(Timestamp.parse("2026-09-02T00:00:00.000Z")!.timeIntervalSince1970)
        await license.start()
        XCTAssertEqual(license.status, .notLicensed(.termEnded))
    }

    func testAClockSetBackIsNoticedBeyondASmallTolerance() async throws {
        try await license.activate(productKey: "SYNTH-GOOD-KEY")
        server.offline = true
        clock.seconds = server.now + 10 * day
        await license.start()
        clock.seconds = server.now + 10 * day - 100
        await license.start()
        XCTAssertTrue(license.status.allowsUse, "a small step back (time sync) is tolerated")
        clock.seconds = server.now + 5 * day
        await license.start()
        XCTAssertEqual(license.status, .notLicensed(.clockRolledBack))
    }

    func testTrialAndDeactivation() async throws {
        try await license.startTrial()
        guard case let .trial(trial) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertEqual(trial.endsAt, Timestamp.parse("2026-12-31T00:00:00.000Z"))
        try await license.activate(productKey: "SYNTH-GOOD-KEY")
        guard case .licensed = license.status else { return XCTFail("a paid key takes precedence over a trial") }
        try await license.deactivate()
        guard case .trial = license.status else { return XCTFail("\(license.status)") }
        XCTAssertEqual(server.seatsUsed, 0)
    }

    func testCheckNowRenewsBeforeTheLeaseIsDue() async throws {
        try await license.activate(productKey: "SYNTH-GOOD-KEY")
        at(server.now + 3600)
        await license.start()
        guard case let .licensed(notDue) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertEqual(notDue.issuedAt.timeIntervalSince1970, TimeInterval(server.now - 3600), "start() does not renew early")
        await license.checkNow()
        guard case let .licensed(renewed) = license.status else { return XCTFail("\(license.status)") }
        XCTAssertEqual(renewed.issuedAt.timeIntervalSince1970, TimeInterval(server.now))
        XCTAssertEqual(try store.load()?.highWater.sequence, 2)
    }

    func testMalformedTermIsRefused() {
        XCTAssertThrowsError(try LeaseVerifier.term(.object(["type": .string("monthly")])))
        XCTAssertNil(try LeaseVerifier.term(nil))
    }
}

/// Counts reads, to keep Keychain access (and any access prompt) to one read per launch.
final class CountingStore: LicenseStore, @unchecked Sendable {
    let inner = MemoryLicenseStore()
    let lock = NSLock()
    var loads = 0
    func load() throws -> LicenseState? { lock.withLock { loads += 1 }; return try inner.load() }
    func commit(_ state: LicenseState) throws { try inner.commit(state) }
    func erase() throws { try inner.erase() }
}

@MainActor
final class StoreAccessTests: XCTestCase {
    func testOneLaunchReadsTheStoreOnce() async throws {
        let server = FakeLicensingServer()
        let store = CountingStore()
        let now = Date(timeIntervalSince1970: TimeInterval(server.now))
        let first = RTFMLicense(integration: server.integration, store: store, appVersion: "1.0", transport: server, now: { now })
        try await first.activate(productKey: "SYNTH-GOOD-KEY")
        await first.checkNow()
        XCTAssertEqual(store.loads, 1)
        let relaunched = RTFMLicense(integration: server.integration, store: store, appVersion: "1.0", transport: server, now: { now })
        await relaunched.checkNow()
        XCTAssertEqual(store.loads, 2)
        XCTAssertTrue(relaunched.status.allowsUse)
    }
}
