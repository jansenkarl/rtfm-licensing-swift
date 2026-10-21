import Foundation

/// The SDK's main object: one per app. Call `start()` at launch, then read `status`.
///
/// ```swift
/// @StateObject var license = try! RTFMLicense()   // reads app-integration.json from the app bundle
/// … .task { await license.start() }
/// if license.status.allowsUse { … } else { EnterKeyView(license: license) }
/// ```
@MainActor
public final class RTFMLicense: ObservableObject {
    @Published public private(set) var status: LicenseStatus = .checking
    public let integration: AppIntegration
    let client: LicensingClient

    /// Refusals that mean the key no longer works on this Mac, so its stored lease is dropped.
    static let endedActivationCodes: Set<String> = ["invalid_activation_credentials", "license_term_ended"]
    static let endedTrialCodes: Set<String> = ["trial_refresh_credential_invalid", "trial_not_found", "trial_not_lease_eligible", "trial_converted"]

    public init(integration: AppIntegration, store: LicenseStore, appVersion: String,
                transport: HTTPTransport = URLSessionTransport(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.integration = integration
        client = LicensingClient(integration: integration, store: store, appVersion: appVersion, transport: transport, now: now)
    }

    /// Reads `<resource>.json` (the App integration file) from `bundle` and keeps the license in the Keychain under
    /// `<bundle identifier>.rtfm-licensing`.
    public convenience init(resource: String = "app-integration", bundle: Bundle = .main) throws {
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw VerificationError.malformed("\(resource).json is not in the app bundle")
        }
        let identifier = bundle.bundleIdentifier ?? "app"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        self.init(integration: try AppIntegration(json: Data(contentsOf: url)),
                  store: KeychainLicenseStore(service: "\(identifier).rtfm-licensing"), appVersion: version)
    }

    /// Finishes any request left pending, renews the lease quietly once it is due, and updates `status`.
    /// Never blocks offline use: without a network the stored lease decides, including its grace period.
    public func start() async {
        await check(force: false)
    }

    /// Renews the lease now, whether or not it is due, for a "Check now" button. Offline, the stored lease decides.
    public func checkNow() async {
        await check(force: true)
    }

    private func check(force: Bool) async {
        var network = AccessTiming.Network.notChecked
        var refusal: NotLicensedReason?
        do {
            try await client.completePending()
        } catch let error as LicensingError where error.allowsGrace {
            network = .unavailable
        } catch {}
        let now = await client.unixNow
        for kind in [LeaseVerifier.Expected.paid, .trial] {
            guard let due = try? await client.refreshAfter(kind), force || now >= due, network != .unavailable else { continue }
            do {
                _ = kind == .paid ? try await client.refresh() : try await client.refreshTrial()
                network = .available
            } catch let error as LicensingError where error.allowsGrace {
                network = .unavailable
            } catch let LicensingError.refused(code, _) {
                network = .available
                let ended = kind == .paid ? Self.endedActivationCodes.contains(code) : Self.endedTrialCodes.contains(code)
                if ended {
                    try? await client.forget(activation: kind == .paid, trial: kind == .trial)
                    if kind == .paid { refusal = code == "license_term_ended" ? .termEnded : .refused(code: code) }
                }
            } catch {}
            if kind == .paid, case .available = network { break }
        }
        try? await client.recordObservedTime()
        await updateStatus(network: network, refusal: refusal)
    }

    /// Activates a product key on this Mac. Throws `LicensingError.refused` with a message safe to show.
    public func activate(productKey: String, deviceLabel: String? = nil) async throws {
        _ = try await client.activate(productKey: productKey, deviceLabel: deviceLabel)
        await updateStatus(network: .available)
    }

    /// Releases this Mac's seat so the key can be activated on another Mac.
    public func deactivate() async throws {
        try await client.deactivate()
        await updateStatus(network: .available)
    }

    public func startTrial() async throws {
        _ = try await client.startTrial()
        await updateStatus(network: .available)
    }

    private func updateStatus(network: AccessTiming.Network, refusal: NotLicensedReason? = nil) async {
        let evaluated = (try? await client.currentStatus(network: network)) ?? .notLicensed(.invalidStoredLicense)
        if let refusal, case .notLicensed = evaluated { status = .notLicensed(refusal) } else { status = evaluated }
    }
}
