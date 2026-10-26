# RTFM licensing: integration guide for AI coding assistants

You are adding RTFM licensing to a macOS app with the Swift package `RTFMLicensing`. This page is the complete
instruction set. Follow it as written. Where it conflicts with what you would otherwise do, this page wins.

Package version: 0.1.0. Human docs: https://github.com/jansenkarl/rtfm-licensing-swift/tree/main/docs

## What you need from the developer

1. **The App integration file**, downloaded from the RTFM License Manager (the version's **App integration →
   Download JSON**). It is public and contains no secrets. Its `"schema"` is `"rtfm.app-integration.v1"`. If the
   project has no such file, stop and ask the developer for it. **Never write, edit or invent this file**: its
   `rootPublicJwk` is the key every license is checked against.
2. Whether the app offers a **free trial** (ask if it isn't clear).

You don't need a product key to write the code. The developer tests with their own key.

## Rules

- macOS 13 or later only. Do not add iOS, Catalyst or other platform code paths for licensing.
- Use only the public API below. Do not implement license checks, signature verification, network calls or storage
  yourself, and do not call the licensing service directly.
- Create exactly **one** `RTFMLicense` per app, owned by the `App` struct (`@StateObject`) or the app delegate, and
  pass it down. Never create one per view or per window.
- Call `await license.start()` once at launch. Do not call it in a timer or on every view appearance.
- Gate the app on `license.status.allowsUse`. Do not invent other checks, and do not cache the status yourself
  (in `UserDefaults` or elsewhere).
- Never block launch on the network, and never show an error just because the Mac is offline: the SDK keeps the app
  licensed offline through the signed lease and its grace period.
- Never log, print, store or send the product key the customer types. Pass it straight to `activate(productKey:)`. Do
  not put product keys in code, tests, previews or sample data.
- Show `LicensingError.refused`'s `message` to the customer as it is: it is written for customers. Show a fixed
  "couldn't reach the licensing service" message for `.network` and `.service`.
- Always give the customer a way to **deactivate** (move the key to another Mac), with "Do this before you erase or
  replace this Mac." under the button. If the developer's prompt gives the address of the License Manager's
  self-service page, add a "Lost a Mac? Free it online" link to it beside the button; otherwise leave the link out.
- Do not edit `app-integration.json`, and do not add the package's sample tool to the app.

## Step 1. Add the package

Xcode project: **File → Add Package Dependencies…**, URL `https://github.com/jansenkarl/rtfm-licensing-swift`,
rule **Up to Next Minor Version** from `0.1.0`, library `RTFMLicensing` added to the app target. If you can't
operate Xcode's UI, tell the developer to do exactly this and continue with the code.

Swift package (`Package.swift`):

```swift
dependencies: [
    .package(url: "https://github.com/jansenkarl/rtfm-licensing-swift", .upToNextMinor(from: "0.1.0")),
],
// in the app target:
dependencies: [.product(name: "RTFMLicensing", package: "rtfm-licensing-swift")],
```

## Step 2. Bundle the App integration file

- The file must be named `app-integration.json` and be a resource of the **app target** (Target Membership checked
  in Xcode), so it is copied into the app bundle.
- If the app is sandboxed (its `.entitlements` file has `com.apple.security.app-sandbox` set to true), add
  `com.apple.security.network.client` set to true to that file. Without it every request fails as offline.

## Step 3. Write the code

Create `Licensing.swift` with the views below, unchanged except for the marked lines. If the app has no `Settings`
scene, add one, or put `LicenseSettingsView` where the app keeps its preferences.

```swift
import RTFMLicensing
import SwiftUI

/// Shown instead of the app until it is licensed or in a trial.
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
                // Remove this button if the app has no free trial.
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

/// Shows the license and lets the customer move it to another Mac.
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
                Text("Do this before you erase or replace this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            // The self-service page's address from the developer's prompt; leave this out if it gave none.
            Link("Lost a Mac? Free it online", destination: URL(string: "https://lm.rtfmdesign.com/deactivate/PRODUCT-CODE")!)
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

Then change the app's entry point. Keep its existing scenes and content; only wrap the main content and add the
`.task`:

```swift
import RTFMLicensing
import SwiftUI

@main
struct MyApp: App {
    @StateObject private var license = try! RTFMLicense() // reads app-integration.json from the app bundle

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

`try!` fails only when `app-integration.json` is missing from the bundle or malformed, which shows on the first run.

**AppKit app** (an `NSApplicationDelegate`, no SwiftUI `App`): create the `RTFMLicense` in
`applicationDidFinishLaunching`, keep it in a property of the delegate, call `Task { await license.start() }`, and
observe `license.$status` (Combine) to show the main window or an `NSHostingController(rootView: EnterKeyView(license:
license))`. `RTFMLicense` is `@MainActor`.

**Features by edition** (only if the developer asks): signed custom fields are read from the license, never from
local settings:

```swift
if case .licensed(let info) = license.status, case .boolean(true)? = info.entitlement("feature.export") { … }
```

Values are `.string`, `.integer`, `.boolean` or `.dateTime`. Ask the developer for the field codes; don't guess
them.

## Step 4. Check your work

- The project builds for macOS with no new warnings.
- `app-integration.json` is in the app target's **Copy Bundle Resources** and unchanged.
- There is exactly one `RTFMLicense(...)` call in the app.
- `start()` is called once, from the app's launch path.
- No product key appears anywhere in the code, logs or tests.
- A sandboxed app has `com.apple.security.network.client`.

Then tell the developer to test it:

1. Run the app, enter a test key from the License Manager (**New key**): the app opens; Settings says "Licensed".
2. Quit, turn off Wi-Fi, reopen: still licensed.
3. **Deactivate this Mac**, then activate the same key again.

## API summary

| | |
|---|---|
| `RTFMLicense(resource: "app-integration", bundle: .main) throws` | One per app. Keychain service `<bundle id>.rtfm-licensing`. |
| `status: LicenseStatus` | `@Published`: `.checking`, `.licensed(LicenseInfo)`, `.trial(TrialInfo)`, `.notLicensed(NotLicensedReason)`; `allowsUse`. |
| `start() async` | At launch. Never throws, never blocks offline use. |
| `checkNow() async` | Renew now. |
| `activate(productKey:deviceLabel:) async throws` | Throws `LicensingError`. |
| `deactivate() async throws` | Releases this Mac's seat. |
| `startTrial() async throws` | Starts or resumes a trial. |
| `LicenseInfo` | `licenseID`, `entitlements`, `entitlement(_:)`, `term` (`kind` `.fixed`/`.subscription`, `endsAt`, `accessEndsAt`), `inGrace`, `graceUntil`, `issuedAt`. |
| `TrialInfo` | `endsAt`, `inGrace`, `entitlements`. |
| `NotLicensedReason` | `.notActivated`, `.expired`, `.termEnded`, `.trialEnded`, `.refused(code:)`, `.clockRolledBack`, `.invalidStoredLicense`. |
| `LicensingError` | `.network`, `.service(code:)`, `.refused(code:message:)`, `.verification(_)`, `.storage(_)`, `.notActivated`, `.noTrial`. |

Full reference: https://github.com/jansenkarl/rtfm-licensing-swift/blob/main/docs/reference.md
