# Getting started

This guide takes a macOS app from no licensing to selling keys: set up the product in the RTFM License Manager, add
the package, gate the app, test with a real key, then ship.

Using an AI coding assistant? Add your App integration file to the project and give the assistant the prompt from
**Copy AI prompt** in the License Manager; see [the end of this page](#using-an-ai-assistant).

## 1. Set up your product in the License Manager

1. **Create a product** for your app. A product has versions; each version holds the rules for its keys and trials:
   how many Macs a key covers, how many times a key can be moved to another Mac, and how long a trial lasts.
2. **Enable the version** so it accepts new keys.
3. Optional: add **custom fields** to the version, such as an edition or a feature flag. Each has a code (lowercase,
   for example `edition` or `feature.export`) and is signed into every lease, so the app can trust it.
4. Choose **App integration** on the version and **Download JSON**. The file holds only public values: the licensing
   service's address, the product and version codes, and the root key your app uses to check every license. Nothing
   in it is secret.
5. Choose **New key** to make a key for yourself to test with.

## 2. Add the package

In Xcode, choose **File → Add Package Dependencies…**, enter

```
https://github.com/jansenkarl/rtfm-licensing-swift
```

and choose **Up to Next Minor Version** from `0.1.0`. Add the `RTFMLicensing` library to your app target.

Or, in a `Package.swift`:

```swift
.package(url: "https://github.com/jansenkarl/rtfm-licensing-swift", .upToNextMinor(from: "0.1.0")),
```

Requirements: macOS 13 or later, Swift 5.9 or later. The package has no dependencies beyond Apple's frameworks.

## 3. Add the App integration file

Rename the downloaded file to `app-integration.json` and drag it into your project. Make sure **Target Membership**
includes your app, so it is copied into the app bundle.

If your app is sandboxed, turn on **Outgoing Connections (Client)** under **Signing & Capabilities → App Sandbox**.
Without it every request fails as if the Mac were offline.

## 4. Gate the app

Create one `RTFMLicense` for the whole app, start it at launch, and show your app when `status.allowsUse` is true:

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
        Settings { LicenseSettingsView(license: license) }
    }
}
```

`start()` never blocks offline use. It finishes any request a previous launch left unfinished, renews the lease if it
is due, and sets `status`. Without a network the stored lease decides, including its grace period.

`try!` is safe here as long as `app-integration.json` is in the bundle and unedited: it fails only if the file is
missing or malformed, which you see the first time you run the app.

## 5. Ask for a key

```swift
struct EnterKeyView: View {
    @ObservedObject var license: RTFMLicense
    @State private var key = ""
    @State private var message = ""
    @State private var working = false

    var body: some View {
        Form {
            if case .notLicensed(let reason) = license.status, let text = reason.explanation { Text(text) }
            TextField("Product key", text: $key)
            HStack {
                Button("Activate") { run { try await license.activate(productKey: key) } }
                    .disabled(key.isEmpty)
                Button("Start free trial") { run { try await license.startTrial() } }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(working || license.status == .checking)
        .padding()
    }

    private func run(_ operation: @escaping () async throws -> Void) {
        working = true
        message = ""
        Task {
            do { try await operation() } catch { message = describe(error) }
            working = false
        }
    }
}

/// A message for a failed activation, deactivation or trial start.
func describe(_ error: Error) -> String {
    switch error {
    case LicensingError.refused(_, let message): message // written by the licensing service, safe to show
    case LicensingError.network, LicensingError.service:
        "Couldn't reach the licensing service. Check your connection and try again."
    default: "Something went wrong with the license. Please try again."
    }
}

extension NotLicensedReason {
    /// Why the app is asking for a key, or nil for a first launch.
    var explanation: String? {
        switch self {
        case .notActivated: nil
        case .expired: "Your license needs to be renewed online. Connect to the internet and reopen the app."
        case .termEnded: "Your license has ended. Renew it to keep using the app."
        case .trialEnded: "Your trial has ended. Enter a product key to keep using the app."
        case .refused: "This key no longer works on this Mac. Enter a product key."
        case .clockRolledBack: "Your Mac's date and time look wrong. Correct them in System Settings, then reopen the app."
        case .invalidStoredLicense: "Your license needs to be activated again."
        }
    }
}
```

Remove the trial button if you don't offer trials.

## 6. Show the license and let customers move it

Customers need to see what they have and to release a Mac when they replace it:

```swift
struct LicenseSettingsView: View {
    @ObservedObject var license: RTFMLicense
    @State private var message = ""

    var body: some View {
        Form {
            Text(summary)
            if case .licensed = license.status {
                Button("Check now") { Task { await license.checkNow() } }
                Button("Deactivate this Mac") {
                    Task {
                        do { try await license.deactivate() } catch { message = describe(error) }
                    }
                }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
        }
        .padding()
    }

    private var summary: String {
        switch license.status {
        case .checking:
            return "Checking your license…"
        case .licensed(let info):
            if info.inGrace {
                return "Licensed. The licensing service couldn't be reached; the app works until "
                    + info.graceUntil.formatted(date: .abbreviated, time: .shortened) + "."
            }
            guard let term = info.term else { return "Licensed." }
            let date = term.endsAt.formatted(date: .abbreviated, time: .omitted)
            return term.kind == .subscription ? "Licensed. Renews \(date)." : "Licensed. Ends \(date)."
        case .trial(let info):
            return "Trial. Ends " + info.endsAt.formatted(date: .abbreviated, time: .shortened) + "."
        case .notLicensed:
            return "Not licensed."
        }
    }
}
```

**Deactivate** releases this Mac's seat so the key can be activated on another Mac. A version can limit how many
times a key may be moved; past the limit the service refuses with `deactivation_limit_reached`.

## 7. Read custom fields

Signed values, including your custom fields, are on the license:

```swift
if case .licensed(let info) = license.status, case .string(let edition)? = info.entitlement("edition") {
    // "pro", "standard", …
}
```

A value is `.string`, `.integer`, `.boolean` or `.dateTime`. The system value `activation.limit` is the number of Macs
the key covers.

## 8. Test it

Run the app, enter your test key, and check:

- the app opens and Settings shows "Licensed";
- quit, turn off Wi-Fi, reopen: still licensed;
- **Deactivate this Mac**, then activate the same key again.

You can also try the key from Terminal without building your app, with the sample tool in this repository:

```sh
git clone https://github.com/jansenkarl/rtfm-licensing-swift
cd rtfm-licensing-swift
swift run rtfm-license-sample ~/Downloads/app-integration.json activate   # asks for the key, hidden
swift run rtfm-license-sample ~/Downloads/app-integration.json status
swift run rtfm-license-sample ~/Downloads/app-integration.json deactivate
```

The sample keeps its license in the login Keychain apart from your app's, so it uses a seat of its own: deactivate it
when you're done.

## 9. Ship

- Sign the app with your Developer ID and keep the same bundle identifier and team in every update. The license is in
  a Keychain item that builds signed by the same team read without asking the customer.
- Ship the App integration file for the environment your customers use (its `environment` field says which).
- To sell keys, connect your store: [Selling with FastSpring](fastspring.md).

## Using an AI assistant

Add your App integration file to the project first. Then, in the License Manager's **App integration** window,
choose **Copy AI prompt** and paste it into your assistant. The prompt names this package and
[the AI integration guide](ai-integration-guide.md), and describes your version: its IDs, trial length, seats per
key and the custom fields the app can read.

Without the License Manager at hand, this general prompt works too:

```text
Add RTFM licensing to this macOS app with the Swift package
https://github.com/jansenkarl/rtfm-licensing-swift (from 0.1.0).
Follow the integration guide exactly:
https://raw.githubusercontent.com/jansenkarl/rtfm-licensing-swift/main/docs/ai-integration-guide.md
The App integration file is app-integration.json in the project. Do not change it.
```
