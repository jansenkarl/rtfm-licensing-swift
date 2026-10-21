# RTFMLicensing

Swift package for adding RTFM License Manager licensing to a macOS app: product key activation, offline use with
signed leases, renewal, deactivation and trials.

**Private preview. Not released and not supported yet.**

- Requires macOS 13 or later and Swift 5.9 or later.
- No hardware fingerprinting: each installation has its own key in the app's Keychain.

## Status

- **M1, verification core (done):** App integration file, root-signed Product manifest, paid and trial leases (signature,
  scope, high-water marks, typed entitlements), expiry and network grace, and the signing-key rotation rule. Tested
  against the licensing server's shared conformance fixtures and its server-signed golden leases.
- **M2, storage (done):** the whole license state is one Keychain item, replaced atomically on each commit; the
  installation's own P-256 key; high-water marks that only rise.
- Next: the online client (M3), the public API and a sample app (M5).
