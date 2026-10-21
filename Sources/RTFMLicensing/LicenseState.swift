import Foundation

/// Everything the SDK keeps between launches. It is stored as one item, so each commit replaces it whole:
/// a verified response and the high-water marks it raises are saved together or not at all.
public struct LicenseState: Codable, Equatable, Sendable {
    /// The installation's private signing key (P-256, raw representation). Created once, before the first request.
    public var installationKey: Data
    public var activation: Activation?
    /// The latest accepted leases, as signed JWS; verified again on every launch.
    public var paidLease: String?
    public var trialLease: String?
    public var trialID: String?
    /// The newest root-signed manifest held (JWS).
    public var manifest: String?
    public var highWater = HighWater()
    /// When the manifest was last fetched again for each unlisted `kid`.
    public var manifestRefetches: [String: Date] = [:]
    /// A paid request written down before it was sent, replayed exactly until its response is committed.
    public var pendingOperation: PendingOperation?

    public struct Activation: Codable, Equatable, Sendable {
        public var activationID: String
        public var refreshCredential: String
    }

    /// Endpoint, exact body and idempotency key of a request that may already have reached the server.
    public struct PendingOperation: Codable, Equatable, Sendable {
        public var path: String
        public var body: Data
        public var idempotencyKey: String
    }

    public init(installationKey: Data) {
        self.installationKey = installationKey
    }
}

/// Where `LicenseState` is kept. `commit` must replace the whole state atomically or throw, leaving the previous
/// state in place.
public protocol LicenseStore: Sendable {
    func load() throws -> LicenseState?
    func commit(_ state: LicenseState) throws
    func erase() throws
}

public enum StoreError: Error, Equatable, Sendable {
    /// The stored state could not be read back; nothing in it is trusted.
    case unreadable
    case keychain(OSStatus)
}

/// A store in memory, for tests, SwiftUI previews and apps that manage persistence themselves.
public final class MemoryLicenseStore: LicenseStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    /// When set, the next commits throw this error and leave the stored state unchanged.
    var failCommits: Error?

    public init() {}

    public func load() throws -> LicenseState? {
        try lock.withLock { try data.map(LicenseStateCoding.decode) }
    }

    public func commit(_ state: LicenseState) throws {
        try lock.withLock {
            if let failure = failCommits { throw failure }
            data = try LicenseStateCoding.encode(state)
        }
    }

    public func erase() throws {
        lock.withLock { data = nil }
    }
}

enum LicenseStateCoding {
    static func encode(_ state: LicenseState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(state)
    }

    static func decode(_ data: Data) throws -> LicenseState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let state = try? decoder.decode(LicenseState.self, from: data) else { throw StoreError.unreadable }
        return state
    }
}

extension LicenseState {
    /// The state after accepting a verified lease: the lease, and high-water marks raised to it (never lowered).
    func accepting(_ lease: Lease) -> LicenseState {
        var next = self
        next.highWater.sequence = max(highWater.sequence, lease.sequence)
        switch lease.kind {
        case let .paid(_, _, epoch):
            next.paidLease = lease.jws
            next.highWater.revocationEpoch = max(highWater.revocationEpoch, epoch)
        case let .trial(trialID, _, revision):
            next.trialLease = lease.jws
            next.trialID = trialID
            next.highWater.trialRevision = max(highWater.trialRevision, revision)
        }
        return next
    }

    /// Records the latest wall-clock time seen, so a clock set back later is noticed.
    func observing(_ now: Int64) -> LicenseState {
        var next = self
        next.highWater.observedTime = max(highWater.observedTime, now)
        return next
    }
}
