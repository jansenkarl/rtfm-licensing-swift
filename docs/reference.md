# API reference

Version 0.1.0. Everything an app needs is `RTFMLicense` and the types it returns. The lower-level types are listed at
the end for tests and tools.

## RTFMLicense

`@MainActor final class RTFMLicense: ObservableObject`. Create one per app and keep it for the app's lifetime.

| | |
|---|---|
| `init(resource: String = "app-integration", bundle: Bundle = .main) throws` | Reads `<resource>.json` from the bundle and keeps the license in the Keychain under the service `<bundle identifier>.rtfm-licensing`. Throws `VerificationError.malformed` if the file is missing or invalid. |
| `init(integration:store:appVersion:transport:now:)` | For tests and tools: pass an `AppIntegration`, a `LicenseStore` (for example `MemoryLicenseStore()`), the app version, and optionally an `HTTPTransport` and a clock. |
| `status: LicenseStatus` | Published. `.checking` until `start()` finishes. |
| `integration: AppIntegration` | The parsed App integration file. |
| `start() async` | Call once at launch. Finishes a request left unfinished by an earlier launch, renews the lease if it is due, and updates `status`. Never throws and never blocks offline use. |
| `checkNow() async` | Renews now, even if not due. For a "Check now" button. |
| `activate(productKey: String, deviceLabel: String? = nil) async throws` | Activates a key on this Mac. `deviceLabel` is an optional name for this Mac, shown on the key's page in the License Manager. |
| `deactivate() async throws` | Releases this Mac's seat so the key can be activated on another Mac. |
| `startTrial() async throws` | Starts a trial, or resumes this Mac's trial if it already has one. |

The three throwing methods throw `LicensingError`. A request that can use a seat is saved before it is sent; if the
answer is lost, the next call (or the next `start()`) repeats it exactly, so a lost connection never uses a second
seat.

## LicenseStatus

```swift
enum LicenseStatus: Equatable, Sendable {
    case checking
    case licensed(LicenseInfo)
    case trial(TrialInfo)
    case notLicensed(NotLicensedReason)
    var allowsUse: Bool   // true for .licensed and .trial
}
```

### LicenseInfo

| | |
|---|---|
| `licenseID: String` | The license's ID. |
| `entitlements: [Entitlement]` | Signed values: `activation.limit` and your custom fields. |
| `entitlement(_ code: String) -> Entitlement.Value?` | One value by code. |
| `term: Lease.Term?` | Set for fixed-term and subscription keys; nil for perpetual keys. |
| `inGrace: Bool` | The lease ran out and the service could not be reached; use continues until `graceUntil`. |
| `graceUntil: Date` | The last moment this lease allows use without renewing. |
| `issuedAt: Date` | When the service last confirmed this key. |

### Lease.Term

| | |
|---|---|
| `kind: Kind` | `.fixed` or `.subscription`. |
| `endsAt: Date` | The end of the term, or of the paid subscription period. Show "Ends …" or "Renews …". |
| `accessEndsAt: Date` | When use stops: `endsAt` plus the version's term grace days, if any. After it, `status` is `.notLicensed(.termEnded)`. |

A subscription that renews moves `endsAt` forward at the next lease renewal.

### TrialInfo

| | |
|---|---|
| `endsAt: Date` | When the trial ends. |
| `inGrace: Bool` | As for `LicenseInfo`. |
| `entitlements: [Entitlement]` | The trial's signed values. |

### NotLicensedReason

| Case | Meaning | What to tell the customer |
|---|---|---|
| `.notActivated` | No key and no trial on this Mac. | Ask for a key. |
| `.expired` | The lease and its grace period ran out without reaching the service. | Go online and reopen the app. |
| `.termEnded` | A fixed term or subscription has ended. | Renew. |
| `.trialEnded` | The trial has ended. | Buy a key. |
| `.refused(code:)` | The service refused the key at renewal: revoked, deactivated from another Mac or the License Manager, or no longer valid. The stored license has been removed. | Enter a key. |
| `.clockRolledBack` | The Mac's clock is more than 5 minutes earlier than a time the app has already seen. | Correct the date and time. |
| `.invalidStoredLicense` | The stored license did not verify. | Activate again. |

## Entitlement

```swift
struct Entitlement { let code: String; let value: Value }
enum Entitlement.Value { case string(String), integer(Int64), boolean(Bool), dateTime(Date) }
```

Custom field codes are lowercase: 2 to 64 of `a-z`, `0-9`, `_`, `.` and `-`, starting with a letter.

## LicensingError

| Case | Meaning |
|---|---|
| `.network` | The service could not be reached. |
| `.service(code:)` | The service failed or asked to retry later. Treated like `.network`. |
| `.refused(code:message:)` | The service refused for good. `message` is written for customers and safe to show. Common codes are below. |
| `.verification(VerificationError)` | A response did not verify. Retrying will not help; check that the App integration file is the right one. |
| `.storage(String)` | The Keychain could not be read or written. |
| `.notActivated` | `deactivate()` or a renewal was called with no activation. |
| `.noTrial` | A trial operation was called with no trial. |

`allowsGrace` is true for `.network` and `.service`: only those let an expired lease keep working through its grace
period. A refusal never does.

### Refusal codes

| Code | When |
|---|---|
| `invalid_product_key` | The key is mistyped, revoked or inactive, is for another product or version than the App integration file names, or that version is not enabled. |
| `activation_seat_limit_reached` | The key is active on as many Macs as it covers. The customer deactivates one of them first, in the app or on the self-service page the message names. |
| `deactivation_limit_reached` | The key has been moved as many times as its version allows. |
| `license_term_ended` | The fixed term or subscription has ended. |
| `invalid_activation_credentials` | At renewal or deactivation: this Mac's activation was deactivated elsewhere or the key was revoked. |
| `unsupported_product` | The product or version is not enabled for licensing or trials. |
| `trials_disabled` | Trials are not available. |
| `trial_converted` | This Mac's trial became a paid license. |

## Lower-level types

For tests, tools and custom storage. Apps don't need them.

| Type | Use |
|---|---|
| `AppIntegration(json: Data)` | Parses an App integration file (`rtfm.app-integration.v1`). |
| `LicenseStore` | Protocol: `load()`, `commit(_:)` (atomic), `erase()`. |
| `KeychainLicenseStore(service:account:)` | The default store: one generic-password item in the login Keychain. |
| `MemoryLicenseStore()` | An in-memory store for tests. |
| `HTTPTransport`, `URLSessionTransport` | The network layer; inject a fake in tests. |
| `LicensingClient` | The actor behind `RTFMLicense`, returning verified `Lease` values. |
| `RTFMLicensingInfo.version` | The package version, `"0.1.0"`. |

## Versions

Versions follow [Semantic Versioning](https://semver.org). Before 1.0.0 a minor version (0.x.0) may change the public
API and a patch version (0.x.y) does not, so depend on **Up to Next Minor Version**. Changes are in
[CHANGELOG.md](../CHANGELOG.md).
