# Troubleshooting

## The app crashes at launch in `RTFMLicense()`

`app-integration.json` is not in the app bundle, or it was edited. Check the file's **Target Membership** in Xcode,
and download it again from **App integration** if in doubt. The error names the problem, for example
`app-integration.json is not in the app bundle` or `App integration file is missing productCode`.

## Every activation fails with "Couldn't reach the licensing service"

- **Sandboxed app:** turn on **Outgoing Connections (Client)** under **Signing & Capabilities → App Sandbox**
  (`com.apple.security.network.client`).
- A firewall or network filter blocks the address in `apiBaseUrl`.
- The Mac is offline. Activation needs the network once; after that the app works offline.

## `invalid_product_key`

- The key was mistyped. Case, spaces and dashes don't matter, but every letter and digit does.
- The key was revoked, or the version is not enabled.
- The key is for a different product or version than the App integration file in the app. A key belongs to one
  version: a key for version 1 does not activate an app built with version 2's file.

## `activation_seat_limit_reached`

The key is active on as many Macs as it covers. The customer deactivates it on one of them (your app's
**Deactivate this Mac**). If the customer no longer has that Mac, open the key in the License Manager and choose
**Deactivate** on that Mac's row under Activations. Its seat is free at once, and the customer activates the new Mac
with the same key. The old Mac stops when it next renews its license (the dialog names the latest date). This does not
use one of the key's deactivations.

## `deactivation_limit_reached`

The key has been moved as many times as its version allows. The limit is set with the version's **Edit** action. You
can still free a Mac yourself with **Deactivate** on the key's page in the License Manager; that does not count
against the limit.

## macOS asks for Keychain access

The license is one Keychain item, readable without asking by builds signed with the same bundle identifier and team.
macOS asks when:

- a build is signed only to run locally (ad hoc), as with the sample tool or some Debug builds. Sign Debug builds
  with your Apple Development team;
- the bundle identifier or team changed between builds. Keep both the same in every release.

Choosing **Deny** looks like a missing license; choosing **Allow** fixes it.

## The license is gone after reinstalling

It isn't: the Keychain item survives deleting the app, and a reinstall finds it. A clean install on another Mac has no
license, so the customer activates there, after deactivating the old Mac if they have no seat free.

## Start over on a test Mac

Deactivate first, so the seat is released. Then delete the item: in **Keychain Access**, search for
`<your bundle identifier>.rtfm-licensing` and delete it. For the sample tool, run
`swift run rtfm-license-sample <app-integration.json> reset`.

## `status` is `.notLicensed(.clockRolledBack)`

The Mac's clock is more than 5 minutes earlier than a time the app has already seen. Turn on **Set time and date
automatically** in **System Settings → General → Date & Time**, then reopen the app.

## `status` is `.notLicensed(.expired)`

The Mac was offline longer than the lease and its grace period allow. Going online and reopening the app renews it.

## `status` is `.notLicensed(.refused(code:))` at launch

The service refused the key at renewal: it was revoked, deactivated from another Mac or the License Manager, or the
license ended. The stored license has been removed; activating a valid key works again.

## `LicensingError.verification`

A response did not verify against the App integration file. Retrying will not help. Check that the app ships the file
for the same environment as the service it talks to, downloaded from the right version.

## Still stuck

Open an issue at https://github.com/jansenkarl/rtfm-licensing-swift/issues with the package version, the macOS
version, the error code, and what you did. **Never include a product key**, a customer's email or anything from the
Keychain item.
