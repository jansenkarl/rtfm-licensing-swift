import Foundation
import RTFMLicensing

// Exercises the SDK against a real licensing service, using a downloaded App integration file.
// The license state is kept in the login Keychain under "com.rtfmdesign.licensing.sample.<product code>".

let usage = """
Usage: rtfm-license-sample <app-integration.json> <command>
  status        Check the stored license (renews it quietly when due) and print the status.
  activate      Activate a product key on this Mac (the key is read without being shown).
  renew         Renew the lease now, even if it is not due, and print the status.
  deactivate    Release this Mac's seat.
  trial         Start or resume a trial.
  reset         Forget the license stored on this Mac (does not release the seat).
"""

@MainActor
func run() async -> Int32 {
    let arguments = CommandLine.arguments.dropFirst()
    guard arguments.count == 2, let path = arguments.first, let command = arguments.last else {
        print(usage)
        return 2
    }
    do {
        let integration = try AppIntegration(json: Data(contentsOf: URL(fileURLWithPath: path)))
        let store = KeychainLicenseStore(service: "com.rtfmdesign.licensing.sample.\(integration.productCode)")
        let license = RTFMLicense(integration: integration, store: store, appVersion: RTFMLicensingInfo.version)
        print("\(integration.productCode) / \(integration.productVersionCode) on \(integration.issuer)")
        switch command {
        case "status": await license.start()
        case "renew": await license.checkNow()
        case "activate":
            guard let key = getpass("Product key (not shown): ").map({ String(cString: $0) }), !key.isEmpty else { return 2 }
            try await license.activate(productKey: key)
        case "deactivate":
            await license.start()
            try await license.deactivate()
        case "trial": try await license.startTrial()
        case "reset":
            try store.erase()
            print("Stored license forgotten.")
            return 0
        default:
            print(usage)
            return 2
        }
        print(describe(license.status))
        return 0
    } catch let LicensingError.refused(code, message) {
        print("Refused (\(code)): \(message)")
    } catch {
        print("Failed: \(error)")
    }
    return 1
}

func describe(_ status: LicenseStatus) -> String {
    let date = { (value: Date) in value.formatted(date: .abbreviated, time: .shortened) }
    switch status {
    case .checking: return "Checking…"
    case let .licensed(info):
        var lines = ["Licensed (license \(info.licenseID)), lease issued \(date(info.issuedAt))"]
        if let term = info.term {
            lines.append(term.kind == .subscription ? "Renews \(date(term.endsAt)) · works until \(date(term.accessEndsAt))"
                                                    : "Ends \(date(term.endsAt)) · works until \(date(term.accessEndsAt))")
        }
        if info.inGrace { lines.append("Offline grace until \(date(info.graceUntil)): go online to renew") }
        lines += info.entitlements.map { "  \($0.code) = \($0.value)" }
        return lines.joined(separator: "\n")
    case let .trial(trial): return "Trial until \(date(trial.endsAt))" + (trial.inGrace ? " (offline grace)" : "")
    case let .notLicensed(reason): return "Not licensed: \(reason)"
    }
}

exit(await run())
