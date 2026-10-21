# RTFMLicensing

Swift package for adding RTFM License Manager licensing to a macOS app: product key activation, offline use with
signed leases, quiet renewal, deactivation, trials, and fixed-term or subscription keys.

**Private preview. Not released and not supported yet.**

- macOS 13 or later, Swift 5.9 or later. No dependencies beyond Apple's CryptoKit and Security frameworks.
- No hardware fingerprinting: each installation has its own key in the app's Keychain.
- Works offline: a lease lasts weeks, and if the service can't be reached when it runs out, a grace period follows.

## Quickstart

1. In the License Manager, open your Product Version and choose **App integration**, then download the file. Add it
   to your app target as `app-integration.json`. It holds only public values.
2. In Xcode, choose **File → Add Package Dependencies…** and add this repository.
3. Create one `RTFMLicense` for the app, check it at launch, and ask for a key when it doesn't allow use:

```swift
import RTFMLicensing
import SwiftUI

@main
struct MyApp: App {
    @StateObject private var license = try! RTFMLicense() // reads app-integration.json from the bundle

    var body: some Scene {
        WindowGroup {
            Group {
                if license.status.allowsUse { ContentView() } else { EnterKeyView(license: license) }
            }
            .task { await license.start() }
        }
    }
}

struct EnterKeyView: View {
    @ObservedObject var license: RTFMLicense
    @State private var key = ""
    @State private var message = ""

    var body: some View {
        Form {
            TextField("Product key", text: $key)
            Button("Activate") {
                Task {
                    do { try await license.activate(productKey: key) }
                    catch LicensingError.refused(_, let text) { message = text } // safe to show
                    catch { message = "Couldn't reach the licensing service. Check your connection and try again." }
                }
            }
            if !message.isEmpty { Text(message) }
        }
    }
}
```

`license.status` is one of:

| Status | Meaning |
|---|---|
| `.licensed(info)` | A key is active. `info.term` is set for fixed-term and subscription keys ("Renews …" or "Ends …"); `info.inGrace` means the lease ran out offline and use continues until `info.graceUntil`; `info.entitlement("code")` reads signed entitlements, including your custom license fields. |
| `.trial(info)` | A trial runs until `info.endsAt`. Start one with `license.startTrial()`. |
| `.notLicensed(reason)` | Ask for a key. `reason` says why: `.notActivated`, `.expired`, `.termEnded`, `.trialEnded`, `.refused(code:)`, `.clockRolledBack`, `.invalidStoredLicense`. |
| `.checking` | Before `start()` finishes. |

Offer **Deactivate** (`license.deactivate()`) so a customer can move their key to another Mac.
`license.checkNow()` renews the lease immediately, for a "Check now" button; `start()` renews only when the lease
is due.

## Try it from Terminal

The sample tool makes the same calls against a real licensing service, using your App integration file:

```sh
swift run rtfm-license-sample ~/Downloads/app-integration-my-app-1-staging.json activate   # asks for the key, hidden
swift run rtfm-license-sample ~/Downloads/app-integration-my-app-1-staging.json status
swift run rtfm-license-sample ~/Downloads/app-integration-my-app-1-staging.json deactivate
```

## How it works

- At first launch the SDK creates a P-256 key for this installation and stores it, with everything else, as one
  Keychain item that is replaced atomically.
- Activation sends the product key with a signed one-time challenge. The service answers with a signed lease bound to
  this installation. The SDK checks it against your Product's key list, which is signed by the root key pinned in
  `app-integration.json`.
- Every request that can use a seat is saved before it is sent and repeated exactly if the answer is lost, so a
  dropped connection never uses a second seat.
- Leases renew quietly once due. Only a network or service failure allows the grace period; a revoked or ended key
  stops at its next renewal.

## Status

- **M1, verification core:** manifests, paid and trial leases, entitlements, timing and grace, key rotation. Tested
  with the licensing server's shared conformance fixtures and its server-signed golden leases.
- **M2, storage:** Keychain state, replaced atomically; high-water marks that only rise.
- **M3, online client:** challenges, activation, refresh, deactivation and trials, with requests journaled and replayed.
- **M5, public API:** `RTFMLicense`, `LicenseStatus`, the term of fixed-term and subscription keys, and the sample tool.
- Next: acceptance against the staging service (M6), then release 0.1.0 (M7).
