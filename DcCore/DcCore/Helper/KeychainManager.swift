import Foundation
import Security

public enum KeychainError: Error {
    case noPassword
    case accessError(message: String, status: OSStatus)
    case unhandledError(message: String, status: OSStatus)
}

public class KeychainManager {
    private typealias KcM = KeychainManager
    // the development team id is equivalent to $(AppIdentifierPrefix) in deltachat-ios.entitlements
    // It is required as a prefix for the shared keychain identifier, but not straight forward to access programmatically,
    // so we're hardcoding it here
    private static let teamId = "U97T6JQUY7" // Roman Valchuk Team ID
    private static let keychainGroupSuffix = "group.romanvalchuk.altchat"
    private static let sharedKeychainGroup = "\(KcM.teamId).\(KcM.keychainGroupSuffix)"

    public static func getAccountSecret(accountID: Int) throws -> String {
        do {
            return try queryAccountSecret(id: accountID)
        } catch KeychainError.noPassword {
            return try addAccountSecret(id: accountID)
        }
    }

    /**
     * Deletes ALL secrets from keychain
     * @return true if secrets have been deleted successfully or no secrets found
     */
    public static func deleteDBSecrets() -> Bool {
        let query = [kSecClass as String: kSecClassGenericPassword,
                     kSecAttrAccessGroup as String: KcM.sharedKeychainGroup as AnyObject
                    ] as CFDictionary

        let status = SecItemDelete(query)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /**
     * Tries to deletes the secret for a given account id, errors will be ignored
     */
    public static func deleteAccountSecret(id: Int) {
        let query = [
          kSecAttrAccount as String: "\(id)",
          kSecClass: kSecClassGenericPassword,
          kSecAttrAccessGroup as String: KcM.sharedKeychainGroup as AnyObject,
          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary
        _ = SecItemDelete(query)
    }

    private static func createRandomPassword() -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXZY1234567890"
        return String((0..<36).map { _ in letters.randomElement()! })
    }

    private static func addAccountSecret(id: Int) throws -> String {
        let keychainItemQuery = [
          kSecValueData: createRandomPassword().data(using: .utf8)!,
          kSecAttrAccount as String: "\(id)",
          kSecClass: kSecClassGenericPassword,
          kSecAttrAccessGroup as String: KcM.sharedKeychainGroup as AnyObject,
          kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ] as CFDictionary

        let status = SecItemAdd(keychainItemQuery, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandledError(message: "Error adding secret for account \(id)",
                                               status: status)
        }
        UserDefaults.shared?.set(true, forKey: UserDefaults.hasSavedKeyToKeychain)
        return try queryAccountSecret(id: id)
    }

    private static func queryAccountSecret(id: Int) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrAccount as String: "\(id)",
                                    kSecMatchLimit as String: kSecMatchLimitOne,
                                    kSecAttrAccessGroup as String: KcM.sharedKeychainGroup as AnyObject,
                                    kSecReturnAttributes as String: true,
                                    kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw KeychainError.noPassword
        case errSecInteractionNotAllowed:
            throw KeychainError.accessError(message: "Keychain not yet available.", status: status)
        default:
            throw KeychainError.unhandledError(message: "Unknown error while querying secret for account \(id):",
                                               status: status)
        }
        
        guard let existingItem = item as? [String: Any],
            let passwordData = existingItem[kSecValueData as String] as? Data,
            let password = String(data: passwordData, encoding: String.Encoding.utf8)
        else {
            throw KeychainError.unhandledError(message: "Unexpected password data for accuont \(id)",
                                               status: 0)
        }
        return password
    }

    // MARK: - Alt Platform JWT & Recovery Password

    public static func saveJwtToken(_ token: String, accountId: Int) {
        let data = token.data(using: .utf8)!
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "alt_jwt",
            kSecAttrAccount as String: "\(accountId)",
            kSecAttrAccessGroup as String: KcM.sharedKeychainGroup
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "alt_jwt",
            kSecAttrAccount as String: "\(accountId)",
            kSecAttrAccessGroup as String: KcM.sharedKeychainGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public static func loadJwtToken(accountId: Int) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "alt_jwt",
            kSecAttrAccount as String: "\(accountId)",
            kSecAttrAccessGroup as String: KcM.sharedKeychainGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func saveRecoveryPassword(_ password: String) {
        let data = password.data(using: .utf8)!
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "alt_recovery",
            kSecAttrAccount as String: "alt_recovery_password",
            kSecAttrAccessGroup as String: KcM.sharedKeychainGroup
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "alt_recovery",
            kSecAttrAccount as String: "alt_recovery_password",
            kSecAttrAccessGroup as String: KcM.sharedKeychainGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    public static func loadRecoveryPassword() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "alt_recovery",
            kSecAttrAccount as String: "alt_recovery_password",
            kSecAttrAccessGroup as String: KcM.sharedKeychainGroup,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
