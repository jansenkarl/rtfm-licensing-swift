# RTFM Licensing Swift Package

Swift package for adding RTFM License Manager licensing to a macOS app: product key activation, offline use with
signed leases, quiet renewal, deactivation, trials, and fixed-term or subscription keys.

**Version 0.1.0.** MIT licensed (see `LICENSE`). Changes are listed in `CHANGELOG.md`.

**Docs:** [Getting started](docs/getting-started.md) · [API reference](docs/reference.md) ·
[Selling with FastSpring](docs/fastspring.md) · [Troubleshooting](docs/troubleshooting.md) ·
[AI integration guide](docs/ai-integration-guide.md) ([`llms.txt`](llms.txt))

- macOS 13 or later, Swift 5.9 or later. No dependencies beyond Apple's CryptoKit and Security frameworks.
- No hardware fingerprinting: each installation has its own key in the app's Keychain.
- Works offline: a lease lasts weeks, and if the service can't be reached when it runs out, a grace period follows.

## Quickstart

1. In the License Manager, open your Product Version and choose **App integration**, then download the file. Add it
   to your app target as `app-integration.json`. It holds only public values.
2. In Xcode, choose **File → Add Package Dependencies…**, add this repository, and choose "Up to Next Minor Version"
   from 0.1.0.
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

The full walkthrough, with a settings view showing the license and a **Deactivate this Mac** button, is in
[Getting started](docs/getting-started.md).

## Using an AI coding assistant

Put your App integration file in the project and give the assistant this prompt:

```text
Add RTFM licensing to this macOS app with the Swift package
https://github.com/jansenkarl/rtfm-licensing-swift (from 0.1.0).
Follow the integration guide exactly:
https://raw.githubusercontent.com/jansenkarl/rtfm-licensing-swift/main/docs/ai-integration-guide.md
The App integration file is app-integration.json in the project. Do not change it.
```

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

0.1.0 was tested against the RTFM licensing staging service: activation of a fixed-term key, status at launch,
renewal, deactivation, reactivation, a refused key and a trial. Builds signed with Developer ID read and update their
Keychain item after an app update without prompts.
