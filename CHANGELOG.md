# Changelog

Versions follow [Semantic Versioning](https://semver.org). Before 1.0.0, a minor version (0.x.0) may change the
public API; a patch version (0.x.y) does not.

## 0.1.0 (2026-10-21)

First version, tested against the RTFM licensing staging service.

- `RTFMLicense`: activation, quiet renewal at launch, `checkNow()`, deactivation and trials, with a `status` for
  SwiftUI (`licensed`, `trial`, `notLicensed(reason)`).
- Leases verified against the Product's root-signed key list, with signing-key rotation, scope checks, high-water
  marks per activation, license and trial, typed entitlements, and the term of fixed-term and subscription keys.
- Offline use until the lease's grace period ends; only network and service failures allow grace.
- One Keychain item per app, replaced atomically; requests that can use a seat are journaled and replayed exactly
  after a lost response.
- `rtfm-license-sample` command-line tool.
