import Foundation
import Security

/// Keeps `LicenseState` as one generic-password item in the app's Keychain. Replacing that single item is atomic.
///
/// The item lives in the user's login Keychain, so it moves with Migration Assistant like the user's other
/// Keychain items. Only the app that created it can read it without a prompt.
public struct KeychainLicenseStore: LicenseStore {
    public let service: String
    public let account: String

    /// `service` should be unique to the app and Product, for example "com.example.MyApp.licensing".
    public init(service: String, account: String = "license-state") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() throws -> LicenseState? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.keychain(status) }
        guard let data = result as? Data else { throw StoreError.unreadable }
        return try LicenseStateCoding.decode(data)
    }

    public func commit(_ state: LicenseState) throws {
        let data = try LicenseStateCoding.encode(state)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = "\(service) license state"
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw StoreError.keychain(added) }
        } else if status != errSecSuccess {
            throw StoreError.keychain(status)
        }
    }

    public func erase() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.keychain(status) }
    }
}
